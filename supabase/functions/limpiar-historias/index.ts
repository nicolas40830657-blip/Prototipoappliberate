// LIBERATE · Edge Function "limpiar-historias"
// Borra las historias que ya cumplieron 24 h: primero la foto del Storage
// (bucket "historias") y después la fila de la tabla. La llama el cron cada hora.
//
// Desplegar:  supabase functions deploy limpiar-historias
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (auth !== `Bearer ${serviceKey}`) {
    return new Response("No autorizado", { status: 401 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey);
  let borradas = 0;

  // Por tandas de 500 para no pasarse de tiempo
  while (true) {
    const { data, error } = await supabase
      .from("historias")
      .select("id, foto_path")
      .lt("expira_at", new Date().toISOString())
      .limit(500);
    if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });
    if (!data || data.length === 0) break;

    const rutas = data.map((h) => h.foto_path).filter(Boolean);
    if (rutas.length) {
      const { error: e2 } = await supabase.storage.from("historias").remove(rutas);
      if (e2) return Response.json({ ok: false, error: e2.message }, { status: 500 });
    }
    const { error: e3 } = await supabase.from("historias").delete().in("id", data.map((h) => h.id));
    if (e3) return Response.json({ ok: false, error: e3.message }, { status: 500 });

    borradas += data.length;
    if (data.length < 500) break;
  }

  return Response.json({ ok: true, borradas });
});
