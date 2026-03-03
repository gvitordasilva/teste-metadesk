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

-- Criação antecipada de whatsapp_conversations para resolver dependências de ordem.
-- A migration 20260128173037 tenta ALTER TABLE nesta tabela, mas ela só é criada
-- formalmente em 20260211152125. Criamos aqui com estrutura mínima (sem FKs para
-- chatbot_flows/chatbot_nodes que ainda não existem); as colunas extras são adicionadas
-- via ALTER TABLE pelas migrations subsequentes.
CREATE TABLE IF NOT EXISTS public.whatsapp_conversations (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  phone_number TEXT NOT NULL,
  contact_name TEXT,
  session_data JSONB DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.whatsapp_conversations ENABLE ROW LEVEL SECURITY;
