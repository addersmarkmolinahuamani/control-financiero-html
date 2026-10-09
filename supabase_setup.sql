-- =========================================================================
-- CONFIGURACIÓN DE SUPABASE: GESTIÓN DE CLIENTES Y LICENCIAS
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

-- 4. Función RPC para autorizar nuevos clientes directamente en auth.users
-- Permite crear usuarios incluso si los registros públicos están desactivados
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
    new_user_id uuid := gen_random_uuid();
    encrypted_pw text;
    caller_email text;
BEGIN
    -- Validar que quien invoca la función es el administrador
    caller_email := auth.jwt() ->> 'email';
    IF caller_email IS NULL OR lower(caller_email) != 'adders.ammh@gmail.com' THEN
        RAISE EXCEPTION 'Acceso no autorizado: Solo el administrador puede crear clientes.';
    END IF;

    -- Validar parámetros
    IF p_email IS NULL OR length(trim(p_email)) < 3 THEN
        RAISE EXCEPTION 'Correo electrónico no válido.';
    END IF;
    IF p_password IS NULL OR length(p_password) < 6 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres.';
    END IF;

    -- Verificar si el usuario ya existe en auth.users
    IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(trim(p_email))) THEN
        RAISE EXCEPTION 'El correo ya se encuentra registrado en el sistema.';
    END IF;

    -- Generar hash seguro de la contraseña
    encrypted_pw := extensions.crypt(p_password, extensions.gen_salt('bf'));

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
        jsonb_build_object('nombre', p_nombre),
        now(),
        now(),
        '',
        '',
        '',
        ''
    );

    -- Registrar o actualizar en la tabla clientes
    INSERT INTO public.clientes (id, email, nombre, creado_por, estado)
    VALUES (new_user_id, lower(trim(p_email)), coalesce(p_nombre, 'Cliente'), auth.uid(), 'activa')
    ON CONFLICT (email) DO UPDATE 
    SET nombre = EXCLUDED.nombre, estado = 'activa';

    RETURN json_build_object(
        'success', true,
        'user_id', new_user_id,
        'email', lower(trim(p_email))
    );
END;
$$;

-- Otorgar permisos de ejecución a usuarios autenticados
GRANT EXECUTE ON FUNCTION public.autorizar_nuevo_cliente(text, text, text) TO authenticated;
