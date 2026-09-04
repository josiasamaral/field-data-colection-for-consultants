/* =====================================================================
   Labor Rural — Gestão de Custos de Produção
   Service worker (v0.3.3)

   O que este arquivo faz, em uma frase:
   guarda uma cópia da ferramenta no próprio celular, para que o endereço
   da Vercel continue abrindo mesmo sem internet (no meio da fazenda).

   Estratégia: REDE PRIMEIRO, cópia local como reserva.
   Isso é importante: sempre que houver internet o celular baixa a versão
   mais nova automaticamente. Você NÃO precisa mexer neste arquivo nem
   pedir para ninguém "limpar o cache" quando publicar uma atualização.

   Nada do Supabase passa por aqui (só endereços do próprio site são
   interceptados), então login e sincronização não são afetados.
   ===================================================================== */

const CACHE = "lr-custos-v0-3-3";

/* arquivos que formam a "casca" do aplicativo */
const CASCA = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icone-192.png",
  "./icone-512.png",
  "./icone-maskable-512.png",
  "./apple-touch-icon.png"
];

/* ---------- instalação: baixa a casca ---------- */
self.addEventListener("install", ev => {
  ev.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.allSettled(CASCA.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

/* ---------- ativação: apaga versões antigas do cache ---------- */
self.addEventListener("activate", ev => {
  ev.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

/* ---------- cada pedido de arquivo ---------- */
self.addEventListener("fetch", ev => {
  const req = ev.request;

  if (req.method !== "GET") return;                 // envios ao Supabase passam direto

  let url;
  try { url = new URL(req.url); } catch (e) { return; }

  if (url.origin !== self.location.origin) return;  // nada de outro domínio é tocado

  ev.respondWith(
    fetch(req)
      .then(resp => {
        if (resp && resp.status === 200 && resp.type === "basic") {
          const copia = resp.clone();
          caches.open(CACHE).then(c => c.put(req, copia)).catch(() => {});
        }
        return resp;
      })
      .catch(() =>
        caches.match(req).then(achou =>
          achou || caches.match("./index.html") || Response.error()
        )
      )
  );
});
