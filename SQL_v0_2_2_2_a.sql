-- =====================================================================
-- LABOR RURAL — Gestão de Custos de Produção
-- SQL da versão 0.2.2.2.a  —  vínculo entre FAZENDA e CONSULTOR
--
-- O QUE ESTE SCRIPT FAZ
--   Hoje a fazenda só guarda o NOME do consultor num campo de texto.
--   Texto não serve para o banco decidir quem pode ver o quê. Este script
--   cria uma coluna com o ID do usuário (criado_por) e liga as regras de
--   segurança (RLS) a ela.
--
-- É SEGURO RODAR MAIS DE UMA VEZ (idempotente).
-- Rode TUDO de uma vez no menu "SQL Editor" do Supabase.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASSO 0 — DIAGNÓSTICO (rode sozinho ANTES, e guarde o resultado)
-- Mostra as regras de segurança que já existem. Se aparecer alguma
-- policy com qual = "true" na tabela fazendas, ela libera tudo para todo
-- mundo e precisa ser removida no PASSO 4.
-- ---------------------------------------------------------------------
-- select tablename, policyname, cmd, qual
--   from pg_policies
--  where schemaname = 'public'
--  order by tablename, policyname;


-- ---------------------------------------------------------------------
-- PASSO 1 — coluna do dono da fazenda
-- ---------------------------------------------------------------------
alter table public.fazendas
  add column if not exists criado_por uuid references auth.users(id);

create index if not exists ix_fazendas_criado_por
  on public.fazendas (criado_por);


-- ---------------------------------------------------------------------
-- PASSO 2 — quem é administrador
-- Função auxiliar: devolve verdadeiro se o usuário logado tem papel
-- 'admin' na tabela perfis. Usada nas policies para o administrador
-- continuar enxergando todas as fazendas.
-- ---------------------------------------------------------------------
create or replace function public.lr_e_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.papel = 'admin' from public.perfis p where p.id = auth.uid()),
    false);
$$;

grant execute on function public.lr_e_admin() to authenticated;


-- ---------------------------------------------------------------------
-- PASSO 3 — adoção das fazendas antigas
-- Casa o texto do campo "consultor" com o nome ou o e-mail do perfil.
-- O que não casar fica com criado_por vazio: o próprio aplicativo
-- carimba o dono na primeira vez que alguém abre a fazenda.
-- ---------------------------------------------------------------------
update public.fazendas f
   set criado_por = p.id
  from public.perfis p
 where f.criado_por is null
   and f.consultor is not null
   and lower(btrim(f.consultor)) = lower(btrim(coalesce(p.nome, '')));

update public.fazendas f
   set criado_por = u.id
  from auth.users u
 where f.criado_por is null
   and f.consultor is not null
   and lower(btrim(f.consultor)) = lower(btrim(coalesce(u.email, '')));


-- ---------------------------------------------------------------------
-- PASSO 4 — regras de segurança (RLS) da tabela fazendas
-- ---------------------------------------------------------------------
alter table public.fazendas enable row level security;

drop policy if exists lr_fazendas_ver     on public.fazendas;
drop policy if exists lr_fazendas_criar   on public.fazendas;
drop policy if exists lr_fazendas_alterar on public.fazendas;
drop policy if exists lr_fazendas_apagar  on public.fazendas;

-- VER: o consultor vê as fazendas dele; as sem dono ficam visíveis até
-- alguém abrir (o app carimba o dono); o administrador vê todas.
create policy lr_fazendas_ver on public.fazendas
  for select to authenticated
  using (criado_por = auth.uid() or criado_por is null or public.lr_e_admin());

-- CRIAR: só dá para criar fazenda em nome próprio (ou sendo admin).
create policy lr_fazendas_criar on public.fazendas
  for insert to authenticated
  with check (criado_por = auth.uid() or criado_por is null or public.lr_e_admin());

-- ALTERAR: idem para editar e para adotar uma fazenda sem dono.
create policy lr_fazendas_alterar on public.fazendas
  for update to authenticated
  using  (criado_por = auth.uid() or criado_por is null or public.lr_e_admin())
  with check (criado_por = auth.uid() or public.lr_e_admin());

-- APAGAR: só o dono ou o administrador.
create policy lr_fazendas_apagar on public.fazendas
  for delete to authenticated
  using (criado_por = auth.uid() or public.lr_e_admin());


-- ---------------------------------------------------------------------
-- PASSO 5 — as tabelas filhas seguem a fazenda
-- Cada lançamento só é visível se a fazenda dele for visível.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['talhoes','inventario','custos','vendas','financeiro'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists lr_%s_tudo on public.%I', t, t);
    execute format($f$
      create policy lr_%s_tudo on public.%I
        for all to authenticated
        using      (exists (select 1 from public.fazendas f
                             where f.id = %I.fazenda_id))
        with check (exists (select 1 from public.fazendas f
                             where f.id = %I.fazenda_id))
    $f$, t, t, t, t);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- PASSO 6 — view de resumo usada pela lista de fazendas
-- ---------------------------------------------------------------------
create or replace view public.vw_fazenda_resumo as
select f.id as fazenda_id,
       (select count(*) from public.talhoes    t where t.fazenda_id = f.id) as talhoes,
       (select count(*) from public.inventario i where i.fazenda_id = f.id) as inventario,
       (select count(*) from public.custos     c where c.fazenda_id = f.id) as custos,
       (select count(*) from public.vendas     v where v.fazenda_id = f.id) as vendas
  from public.fazendas f;

grant select on public.vw_fazenda_resumo to authenticated;


-- ---------------------------------------------------------------------
-- PASSO 7 — conferência (rode e leia o resultado)
-- ---------------------------------------------------------------------
select count(*)                                  as fazendas_no_total,
       count(*) filter (where criado_por is not null) as com_dono,
       count(*) filter (where criado_por is null)     as sem_dono_ainda
  from public.fazendas;


-- =====================================================================
-- O QUE FOI CRIADO OU ALTERADO
--
-- TABELA public.fazendas
--   coluna  criado_por  (uuid, aponta para auth.users.id)  — NOVA
--   índice  ix_fazendas_criado_por                          — NOVO
--   policies lr_fazendas_ver / lr_fazendas_criar /
--            lr_fazendas_alterar / lr_fazendas_apagar       — NOVAS
--
-- FUNÇÃO  public.lr_e_admin()                               — NOVA
--
-- POLICIES nas tabelas filhas (uma por tabela)              — NOVAS
--   lr_talhoes_tudo, lr_inventario_tudo, lr_custos_tudo,
--   lr_vendas_tudo, lr_financeiro_tudo
--
-- VIEW  public.vw_fazenda_resumo                            — RECRIADA
--   colunas: fazenda_id, talhoes, inventario, custos, vendas
-- =====================================================================
