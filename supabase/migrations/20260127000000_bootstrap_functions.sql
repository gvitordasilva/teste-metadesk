-- Funções utilitárias base que devem existir antes de todas as outras migrations.
-- Estas funções são referenciadas pela primeira migration (20260127131459) e precisam
-- ser criadas com antecedência.

-- Função de trigger para atualizar o campo updated_at automaticamente
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Função auxiliar para verificar acesso de admin via RLS.
-- Usa role::TEXT para não depender do enum app_role, que é criado em uma migration posterior.
-- O EXCEPTION handler garante que a função não quebre caso user_roles ainda não exista.
CREATE OR REPLACE FUNCTION public.check_admin_access()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role::TEXT = 'admin'
  );
EXCEPTION WHEN undefined_table THEN
  RETURN false;
END;
$$;
