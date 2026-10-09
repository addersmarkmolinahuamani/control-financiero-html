-- =========================================================================
-- CONFIGURACIÓN DE SUPABASE: GESTIÓN DE CLIENTES Y LICENCIAS (ACTUALIZADO)
-- Ejecuta este script en Supabase Dashboard -> SQL Editor
-- No altera ni modifica ningún registro existente en la tabla 'movimientos'.
-- =========================================================================

-- 1. Crear tabla 'clientes' para almacenar información comercial y licencias
CREATE TABLE IF NOT EXISTS public.clientes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    nombre TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    creado_por UUID REFERENCES auth.users(id),
    estado TEXT DEFAULT 'activa'
);

-- 2. Habilitar Row Level Security (RLS) en la tabla 'clientes'
ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

-- 3. Política RLS: Solo el administrador (adders.ammh@gmail.com) puede ver y gestionar clientes
DROP POLICY IF EXISTS "Admin gestiona clientes" ON public.clientes;
CREATE POLICY "Admin gestiona clientes"
ON public.clientes
FOR ALL
TO authenticated
USING (auth.jwt() ->> 'email' = 'adders.ammh@gmail.com')
WITH CHECK (auth.jwt() ->> 'email' = 'adders.ammh@gmail.com');

-- 4. Auto-vincular a cualquier usuario existente en auth.users (ej. joseph.huaman1998@gmail.com)
INSERT INTO public.clientes (id, email, nombre, creado_por, estado)
SELECT 
    u.id, 
    lower(u.email), 
    coalesce(nullif(u.raw_user_meta_data->>'nombre', ''), split_part(u.email, '@', 1)), 
    (SELECT id FROM auth.users WHERE lower(email) = 'adders.ammh@gmail.com' LIMIT 1),
    'activa'
FROM auth.users u
WHERE lower(u.email) != 'adders.ammh@gmail.com'
ON CONFLICT (email) DO UPDATE 
SET estado = 'activa';

-- 5. Función RPC inteligente: identifica usuarios existentes o crea nuevos
CREATE OR REPLACE FUNCTION public.autorizar_nuevo_cliente(
    p_email text,
    p_password text,
    p_nombre text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
    existing_user_id uuid;
    new_user_id uuid := gen_random_uuid();
    encrypted_pw text;
    caller_email text;
    final_name text;
BEGIN
    -- Validar que quien invoca la función es el administrador
    caller_email := auth.jwt() ->> 'email';
    IF caller_email IS NULL OR lower(caller_email) != 'adders.ammh@gmail.com' THEN
        RAISE EXCEPTION 'Acceso no autorizado: Solo el administrador puede autorizar clientes.';
    END IF;

    -- Validar correo
    IF p_email IS NULL OR length(trim(p_email)) < 3 THEN
        RAISE EXCEPTION 'Ingresa un correo electrónico válido.';
    END IF;

    final_name := coalesce(nullif(trim(p_nombre), ''), split_part(p_email, '@', 1));

    -- 1. CASO: EL USUARIO YA EXISTE EN auth.users (como tu segundo usuario actual)
    SELECT id INTO existing_user_id 
    FROM auth.users 
    WHERE lower(email) = lower(trim(p_email)) 
    LIMIT 1;

    IF existing_user_id IS NOT NULL THEN
        -- Simplemente lo vinculamos y activamos en la tabla clientes sin tocar su contraseña
        INSERT INTO public.clientes (id, email, nombre, creado_por, estado)
        VALUES (existing_user_id, lower(trim(p_email)), final_name, auth.uid(), 'activa')
        ON CONFLICT (email) DO UPDATE 
        SET nombre = coalesce(nullif(EXCLUDED.nombre, ''), public.clientes.nombre), estado = 'activa';

        RETURN json_build_object(
            'success', true,
            'user_id', existing_user_id,
            'email', lower(trim(p_email)),
            'already_exists', true,
            'mensaje', 'Usuario existente identificado y vinculado con éxito.'
        );
    END IF;

    -- 2. CASO: ES UN CLIENTE NUEVO (requiere contraseña inicial)
    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
        RAISE EXCEPTION 'Para un nuevo cliente se requiere una contraseña inicial de al menos 6 caracteres.';
    END IF;

    -- Generar hash seguro de la contraseña
    encrypted_pw := extensions.crypt(trim(p_password), extensions.gen_salt('bf'));

    -- Insertar el nuevo usuario en auth.users con confirmación automática
    INSERT INTO auth.users (
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        email_confirmed_at,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at,
        confirmation_token,
        recovery_token,
        email_change_token_new,
        email_change
    ) VALUES (
        '00000000-0000-0000-0000-00000000000',
        new_user_id,
        'authenticated',
        'authenticated',
        lower(trim(p_email)),
        encrypted_pw,
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('nombre', final_name),
        now(),
        now(),
        '',
        '',
        '',
        ''
    );

    -- Registrar en la tabla clientes
    INSERT INTO public.clientes (id, email, nombre, creado_por, estado)
    VALUES (new_user_id, lower(trim(p_email)), final_name, auth.uid(), 'activa')
    ON CONFLICT (email) DO UPDATE 
    SET nombre = EXCLUDED.nombre, estado = 'activa';

    RETURN json_build_object(
        'success', true,
        'user_id', new_user_id,
        'email', lower(trim(p_email)),
        'already_exists', false,
        'mensaje', 'Nuevo cliente creado y autorizado con éxito.'
    );
END;
$$;

-- Otorgar permisos de ejecución a usuarios autenticados
GRANT EXECUTE ON FUNCTION public.autorizar_nuevo_cliente(text, text, text) TO authenticated;
