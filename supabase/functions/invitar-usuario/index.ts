// Crea un usuario (cobrador/supervisor/admin) dentro del tenant del admin que llama.
// Requiere service role porque usa la API de administración de Auth.
// POST { email, password, nombre, rol, telefono?, documento?, ruta_ids?: string[] }
import { createClient } from 'jsr:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // Quién llama
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
  const { data: { user }, error: authError } = await admin.auth.getUser(token);
  if (authError || !user) return json({ error: 'No autenticado' }, 401);

  const { data: llamador } = await admin
    .from('perfiles').select('tenant_id, rol, activo').eq('id', user.id).single();
  if (!llamador?.activo || llamador.rol !== 'admin') return json({ error: 'Solo el administrador crea usuarios' }, 403);

  const { email, password, nombre, rol, telefono, documento, ruta_ids } = await req.json();
  if (!email || !password || !nombre) return json({ error: 'email, password y nombre son obligatorios' }, 400);
  if (!['admin', 'supervisor', 'cobrador'].includes(rol)) return json({ error: 'Rol inválido' }, 400);
  if (String(password).length < 8) return json({ error: 'La contraseña debe tener al menos 8 caracteres' }, 400);

  const { data: creado, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    app_metadata: { tenant_id: llamador.tenant_id, rol },
  });
  if (createError || !creado.user) return json({ error: createError?.message ?? 'No se pudo crear el usuario' }, 400);

  const { error: perfilError } = await admin.from('perfiles').insert({
    id: creado.user.id, tenant_id: llamador.tenant_id, nombre, rol, telefono, documento,
  });
  if (perfilError) {
    // Ej. límite de cobradores del plan: deshacer el usuario de Auth
    await admin.auth.admin.deleteUser(creado.user.id);
    return json({ error: perfilError.message }, 400);
  }

  if (Array.isArray(ruta_ids) && ruta_ids.length) {
    await admin.from('rutas_usuarios').insert(
      ruta_ids.map((ruta_id: string) => ({ ruta_id, usuario_id: creado.user!.id, tenant_id: llamador.tenant_id })),
    );
  }

  return json({ id: creado.user.id, email, nombre, rol });
});
