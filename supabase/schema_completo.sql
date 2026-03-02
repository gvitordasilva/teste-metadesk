-- ============================================================
-- METADESK: Schema completo (todas as migrations)
-- Cole este SQL no Supabase SQL Editor e execute
-- https://supabase.com/dashboard/project/myywckhuxgqzoaecftdj/sql/new
-- ============================================================

-- -----------------------------------------------------------
-- Migration: 20260127000000_bootstrap_functions.sql
-- -----------------------------------------------------------
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

-- -----------------------------------------------------------
-- Migration: 20260127131459_4e9ed0d2-3a15-4599-bb81-0a186b50fde0.sql
-- -----------------------------------------------------------
-- Criar tabela de reclamações e denúncias
CREATE TABLE public.complaints (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  protocol_number TEXT NOT NULL UNIQUE,
  is_anonymous BOOLEAN NOT NULL DEFAULT false,
  reporter_name TEXT,
  reporter_email TEXT,
  reporter_phone TEXT,
  type TEXT NOT NULL CHECK (type IN ('reclamacao', 'denuncia', 'sugestao')),
  category TEXT NOT NULL,
  occurred_at TIMESTAMPTZ,
  location TEXT,
  description TEXT NOT NULL,
  involved_parties TEXT,
  attachments JSONB DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'novo' CHECK (status IN ('novo', 'em_analise', 'resolvido', 'fechado')),
  internal_notes TEXT,
  assigned_to UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Criar índices para performance
CREATE INDEX idx_complaints_protocol ON public.complaints(protocol_number);
CREATE INDEX idx_complaints_status ON public.complaints(status);
CREATE INDEX idx_complaints_type ON public.complaints(type);
CREATE INDEX idx_complaints_created_at ON public.complaints(created_at DESC);

-- Habilitar RLS
ALTER TABLE public.complaints ENABLE ROW LEVEL SECURITY;

-- Política: Qualquer pessoa pode criar (página pública)
CREATE POLICY "Anyone can create complaints"
ON public.complaints
FOR INSERT
WITH CHECK (true);

-- Política: Apenas admins podem visualizar
CREATE POLICY "Admins can view all complaints"
ON public.complaints
FOR SELECT
USING (public.check_admin_access());

-- Política: Apenas admins podem atualizar
CREATE POLICY "Admins can update complaints"
ON public.complaints
FOR UPDATE
USING (public.check_admin_access());

-- Política: Apenas admins podem deletar
CREATE POLICY "Admins can delete complaints"
ON public.complaints
FOR DELETE
USING (public.check_admin_access());

-- Função para gerar número de protocolo sequencial
CREATE OR REPLACE FUNCTION public.generate_complaint_protocol()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  next_number INTEGER;
  year_suffix TEXT;
BEGIN
  -- Lock para evitar race conditions
  PERFORM pg_advisory_xact_lock(987654);
  
  year_suffix := EXTRACT(YEAR FROM CURRENT_DATE)::TEXT;
  
  SELECT COALESCE(MAX(CAST(SUBSTRING(protocol_number FROM '^REC-\d{4}-(\d+)$') AS INTEGER)), 0) + 1
  INTO next_number
  FROM public.complaints
  WHERE protocol_number ~ ('^REC-' || year_suffix || '-\d+$');
  
  RETURN 'REC-' || year_suffix || '-' || LPAD(next_number::TEXT, 6, '0');
END;
$$;

-- Trigger para atualizar updated_at
CREATE TRIGGER update_complaints_updated_at
BEFORE UPDATE ON public.complaints
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Criar bucket para anexos de reclamações
INSERT INTO storage.buckets (id, name, public)
VALUES ('complaint-attachments', 'complaint-attachments', true)
ON CONFLICT (id) DO NOTHING;

-- Política: Qualquer pessoa pode fazer upload (necessário para página pública)
CREATE POLICY "Anyone can upload complaint attachments"
ON storage.objects
FOR INSERT
WITH CHECK (bucket_id = 'complaint-attachments');

-- Política: Qualquer pessoa pode visualizar anexos
CREATE POLICY "Anyone can view complaint attachments"
ON storage.objects
FOR SELECT
USING (bucket_id = 'complaint-attachments');

-- Política: Apenas admins podem deletar anexos
CREATE POLICY "Admins can delete complaint attachments"
ON storage.objects
FOR DELETE
USING (bucket_id = 'complaint-attachments' AND public.check_admin_access());
-- -----------------------------------------------------------
-- Migration: 20260128134035_f1d28fee-f711-4c36-bfe4-0826dc9376b5.sql
-- -----------------------------------------------------------
-- Criar enum para roles
CREATE TYPE public.app_role AS ENUM ('admin', 'atendente');

-- Criar tabela de roles (separada para segurança)
CREATE TABLE public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    role app_role NOT NULL DEFAULT 'atendente',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (user_id, role)
);

-- Habilitar RLS
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Criar tabela de perfis de atendentes
CREATE TABLE public.attendant_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    email TEXT NOT NULL,
    phone TEXT,
    avatar_url TEXT,
    working_hours JSONB DEFAULT '{"start": "09:00", "end": "18:00"}',
    status TEXT DEFAULT 'offline' CHECK (status IN ('online', 'offline', 'busy', 'break')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.attendant_profiles ENABLE ROW LEVEL SECURITY;

-- Função segura para verificar roles (evita recursão RLS)
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role = _role
  )
$$;

-- Função para obter role do usuário
CREATE OR REPLACE FUNCTION public.get_user_role(_user_id UUID)
RETURNS app_role
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.user_roles
  WHERE user_id = _user_id
  LIMIT 1
$$;

-- Políticas RLS para user_roles
CREATE POLICY "Users can view own role"
ON public.user_roles FOR SELECT
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "Admins can manage all roles"
ON public.user_roles FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Políticas RLS para attendant_profiles
CREATE POLICY "Users can manage own profile"
ON public.attendant_profiles FOR ALL
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "Admins can view all profiles"
ON public.attendant_profiles FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Trigger para atualizar updated_at
CREATE TRIGGER update_attendant_profiles_updated_at
BEFORE UPDATE ON public.attendant_profiles
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();
-- -----------------------------------------------------------
-- Migration: 20260128134919_e3af0c36-be42-4731-bbf7-a8af505fa114.sql
-- -----------------------------------------------------------
-- Remover políticas antigas da tabela complaints
DROP POLICY IF EXISTS "Admins can view all complaints" ON complaints;
DROP POLICY IF EXISTS "Admins can update complaints" ON complaints;
DROP POLICY IF EXISTS "Admins can delete complaints" ON complaints;
DROP POLICY IF EXISTS "Attendants can view assigned complaints" ON complaints;
DROP POLICY IF EXISTS "Attendants can update assigned complaints" ON complaints;

-- Política: Admins veem todas as solicitações
CREATE POLICY "Admins can view all complaints"
ON complaints FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Política: Atendentes veem solicitações atribuídas a eles OU não atribuídas (para pegar novas)
CREATE POLICY "Attendants can view complaints"
ON complaints FOR SELECT
TO authenticated
USING (
  public.has_role(auth.uid(), 'atendente') 
  AND (assigned_to = auth.uid() OR assigned_to IS NULL)
);

-- Política: Admins podem atualizar todas
CREATE POLICY "Admins can update all complaints"
ON complaints FOR UPDATE
TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Política: Atendentes podem atualizar as atribuídas a eles
CREATE POLICY "Attendants can update assigned complaints"
ON complaints FOR UPDATE
TO authenticated
USING (
  public.has_role(auth.uid(), 'atendente') 
  AND assigned_to = auth.uid()
)
WITH CHECK (
  public.has_role(auth.uid(), 'atendente') 
  AND assigned_to = auth.uid()
);

-- Manter política de INSERT público (já existe, mas garantir)
DROP POLICY IF EXISTS "Anyone can create complaints" ON complaints;
CREATE POLICY "Anyone can create complaints"
ON complaints FOR INSERT
TO anon, authenticated
WITH CHECK (true);
-- -----------------------------------------------------------
-- Migration: 20260128140303_9d6114bd-6602-4679-be0a-8920dbbfa21f.sql
-- -----------------------------------------------------------
-- Create workflow_responsibles table
CREATE TABLE public.workflow_responsibles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  position TEXT NOT NULL,
  department TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create workflows table
CREATE TABLE public.workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  workflow_type TEXT,
  is_active BOOLEAN DEFAULT true,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create workflow_steps table
CREATE TABLE public.workflow_steps (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID REFERENCES public.workflows(id) ON DELETE CASCADE NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  responsible_id UUID REFERENCES public.workflow_responsibles(id) ON DELETE SET NULL,
  sla_days INTEGER DEFAULT 1,
  step_order INTEGER NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.workflow_responsibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_steps ENABLE ROW LEVEL SECURITY;

-- RLS Policies for workflow_responsibles
CREATE POLICY "Admins can manage workflow_responsibles"
ON public.workflow_responsibles FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Attendants can view workflow_responsibles"
ON public.workflow_responsibles FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'atendente'));

-- RLS Policies for workflows
CREATE POLICY "Admins can manage workflows"
ON public.workflows FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Attendants can view workflows"
ON public.workflows FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'atendente'));

-- RLS Policies for workflow_steps
CREATE POLICY "Admins can manage workflow_steps"
ON public.workflow_steps FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Attendants can view workflow_steps"
ON public.workflow_steps FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'atendente'));

-- Create indexes for performance
CREATE INDEX idx_workflow_steps_workflow_id ON public.workflow_steps(workflow_id);
CREATE INDEX idx_workflow_steps_responsible_id ON public.workflow_steps(responsible_id);
CREATE INDEX idx_workflows_type ON public.workflows(workflow_type);
CREATE INDEX idx_workflow_responsibles_active ON public.workflow_responsibles(is_active);

-- Create trigger for updated_at
CREATE TRIGGER update_workflow_responsibles_updated_at
BEFORE UPDATE ON public.workflow_responsibles
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_workflows_updated_at
BEFORE UPDATE ON public.workflows
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_workflow_steps_updated_at
BEFORE UPDATE ON public.workflow_steps
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();
-- -----------------------------------------------------------
-- Migration: 20260128160359_2859139e-0335-41f7-b525-5b3d01a25ade.sql
-- -----------------------------------------------------------
-- =============================================
-- SISTEMA AVANÇADO DE ATENDIMENTO - MIGRAÇÃO
-- =============================================

-- 1. Tabela de Mensagens Pré-definidas (Quick Messages)
CREATE TABLE public.quick_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'geral',
  shortcut TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS para quick_messages
ALTER TABLE public.quick_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuários autenticados podem ver mensagens ativas"
  ON public.quick_messages FOR SELECT
  USING (auth.role() = 'authenticated' AND is_active = true);

CREATE POLICY "Admins podem gerenciar mensagens"
  ON public.quick_messages FOR ALL
  USING (public.check_admin_access());

-- Trigger para updated_at
CREATE TRIGGER update_quick_messages_updated_at
  BEFORE UPDATE ON public.quick_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- 2. Tabela de Sessões de Atendimento
CREATE TABLE public.service_sessions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  complaint_id UUID REFERENCES public.complaints(id) ON DELETE SET NULL,
  conversation_id TEXT,
  attendant_id UUID REFERENCES auth.users(id),
  started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  ended_at TIMESTAMP WITH TIME ZONE,
  duration_seconds INTEGER,
  ai_summary TEXT,
  ai_sentiment TEXT,
  forwarded_to_step_id UUID REFERENCES public.workflow_steps(id) ON DELETE SET NULL,
  forward_notes TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'forwarded')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS para service_sessions
ALTER TABLE public.service_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuários autenticados podem ver suas sessões"
  ON public.service_sessions FOR SELECT
  USING (auth.uid() = attendant_id OR public.check_admin_access());

CREATE POLICY "Usuários autenticados podem criar sessões"
  ON public.service_sessions FOR INSERT
  WITH CHECK (auth.uid() = attendant_id);

CREATE POLICY "Usuários autenticados podem atualizar suas sessões"
  ON public.service_sessions FOR UPDATE
  USING (auth.uid() = attendant_id OR public.check_admin_access());

-- Trigger para updated_at
CREATE TRIGGER update_service_sessions_updated_at
  BEFORE UPDATE ON public.service_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- 3. Tabela de Mensagens da Sessão
CREATE TABLE public.service_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES public.service_sessions(id) ON DELETE CASCADE,
  sender_type TEXT NOT NULL CHECK (sender_type IN ('client', 'agent', 'system')),
  content TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS para service_messages
ALTER TABLE public.service_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuários podem ver mensagens de suas sessões"
  ON public.service_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.service_sessions 
      WHERE id = session_id AND (attendant_id = auth.uid() OR public.check_admin_access())
    )
  );

CREATE POLICY "Usuários podem criar mensagens em suas sessões"
  ON public.service_messages FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.service_sessions 
      WHERE id = session_id AND attendant_id = auth.uid() AND status = 'active'
    )
  );

-- 4. Adicionar campos na tabela complaints
ALTER TABLE public.complaints 
  ADD COLUMN IF NOT EXISTS waiting_since TIMESTAMP WITH TIME ZONE DEFAULT now(),
  ADD COLUMN IF NOT EXISTS last_sentiment TEXT,
  ADD COLUMN IF NOT EXISTS current_workflow_step_id UUID REFERENCES public.workflow_steps(id) ON DELETE SET NULL;

-- 5. Índices para performance
CREATE INDEX idx_service_sessions_attendant ON public.service_sessions(attendant_id);
CREATE INDEX idx_service_sessions_status ON public.service_sessions(status);
CREATE INDEX idx_service_sessions_complaint ON public.service_sessions(complaint_id);
CREATE INDEX idx_service_messages_session ON public.service_messages(session_id);
CREATE INDEX idx_quick_messages_category ON public.quick_messages(category);
CREATE INDEX idx_complaints_waiting_since ON public.complaints(waiting_since);

-- 6. Inserir mensagens pré-definidas iniciais
INSERT INTO public.quick_messages (title, content, category, shortcut) VALUES
  ('Saudação Inicial', 'Olá! Meu nome é [NOME] e estou aqui para ajudá-lo(a). Como posso auxiliar hoje?', 'saudacao', '/oi'),
  ('Aguardando Informações', 'Para dar continuidade ao seu atendimento, preciso de algumas informações adicionais. Poderia me fornecer?', 'procedimento', '/info'),
  ('Verificando Sistema', 'Um momento, por favor. Estou verificando as informações no sistema.', 'procedimento', '/aguarde'),
  ('Protocolo Gerado', 'Seu protocolo de atendimento é: [PROTOCOLO]. Guarde este número para futuras consultas.', 'procedimento', '/protocolo'),
  ('Encaminhamento', 'Vou encaminhar seu caso para o setor responsável. Você receberá um retorno em até [PRAZO].', 'procedimento', '/encaminhar'),
  ('Agradecimento Final', 'Agradeço pelo contato! Caso tenha outras dúvidas, estamos à disposição. Tenha um ótimo dia!', 'encerramento', '/tchau'),
  ('Pesquisa de Satisfação', 'Antes de finalizar, gostaria de saber: como você avalia o atendimento prestado hoje?', 'encerramento', '/pesquisa');
-- -----------------------------------------------------------
-- Migration: 20260128171201_33d50f47-0d9c-4abc-a907-eea5a61caa35.sql
-- -----------------------------------------------------------
-- Tabela central para fila de atendimento unificada
CREATE TABLE public.service_queue (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  channel TEXT NOT NULL CHECK (channel IN ('web', 'voice', 'whatsapp', 'email', 'chat')),
  status TEXT NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'in_progress', 'completed', 'forwarded')),
  priority INTEGER NOT NULL DEFAULT 3 CHECK (priority >= 1 AND priority <= 5),
  customer_name TEXT,
  customer_email TEXT,
  customer_phone TEXT,
  customer_avatar TEXT,
  subject TEXT,
  last_message TEXT,
  unread_count INTEGER NOT NULL DEFAULT 1,
  complaint_id UUID REFERENCES public.complaints(id) ON DELETE SET NULL,
  voice_session_id TEXT,
  assigned_to UUID,
  waiting_since TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.service_queue ENABLE ROW LEVEL SECURITY;

-- Index para ordenação por tempo de espera
CREATE INDEX idx_service_queue_waiting ON public.service_queue(waiting_since);
CREATE INDEX idx_service_queue_status ON public.service_queue(status);
CREATE INDEX idx_service_queue_channel ON public.service_queue(channel);
CREATE INDEX idx_service_queue_complaint ON public.service_queue(complaint_id);

-- Enable realtime for this table
ALTER PUBLICATION supabase_realtime ADD TABLE public.service_queue;

-- Policies: Public insert (para formulário público)
CREATE POLICY "Anyone can insert into service_queue"
  ON public.service_queue FOR INSERT
  WITH CHECK (true);

-- Policies: Authenticated users can view
CREATE POLICY "Authenticated users can view service_queue"
  ON public.service_queue FOR SELECT
  TO authenticated
  USING (true);

-- Policies: Authenticated users can update
CREATE POLICY "Authenticated users can update service_queue"
  ON public.service_queue FOR UPDATE
  TO authenticated
  USING (true);

-- Trigger para updated_at
CREATE TRIGGER update_service_queue_updated_at
  BEFORE UPDATE ON public.service_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();
-- -----------------------------------------------------------
-- Migration: 20260128173037_1c94147a-083e-43d7-8c8d-a19cc4f4f9ee.sql
-- -----------------------------------------------------------
-- =============================================
-- CHATBOT DECISION TREE TABLES FOR METADESK
-- =============================================

-- 1. Chatbot Flows - Main flow container
CREATE TABLE public.chatbot_flows (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name text NOT NULL,
  description text,
  channel text NOT NULL DEFAULT 'all' CHECK (channel IN ('whatsapp', 'webchat', 'all')),
  is_active boolean NOT NULL DEFAULT true,
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 2. Chatbot Nodes - Individual nodes in the decision tree
CREATE TABLE public.chatbot_nodes (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  flow_id uuid NOT NULL REFERENCES public.chatbot_flows(id) ON DELETE CASCADE,
  node_type text NOT NULL CHECK (node_type IN ('message', 'menu', 'input', 'action', 'condition')),
  name text NOT NULL,
  content text,
  options jsonb,
  action_type text DEFAULT 'none' CHECK (action_type IN ('none', 'escalate', 'transfer', 'end', 'goto')),
  action_config jsonb,
  next_node_id uuid,
  node_order integer NOT NULL DEFAULT 0,
  is_entry_point boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Add self-reference FK after table creation
ALTER TABLE public.chatbot_nodes 
ADD CONSTRAINT chatbot_nodes_next_node_fk 
FOREIGN KEY (next_node_id) REFERENCES public.chatbot_nodes(id) ON DELETE SET NULL;

-- 3. Chatbot Node Options - Menu options for navigation
CREATE TABLE public.chatbot_node_options (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  node_id uuid NOT NULL REFERENCES public.chatbot_nodes(id) ON DELETE CASCADE,
  option_key text NOT NULL,
  option_text text NOT NULL,
  next_node_id uuid REFERENCES public.chatbot_nodes(id) ON DELETE SET NULL,
  option_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 4. Add current_node_id column to existing whatsapp_conversations
ALTER TABLE public.whatsapp_conversations 
ADD COLUMN IF NOT EXISTS current_node_id uuid REFERENCES public.chatbot_nodes(id) ON DELETE SET NULL;

ALTER TABLE public.whatsapp_conversations 
ADD COLUMN IF NOT EXISTS customer_name text;

ALTER TABLE public.whatsapp_conversations 
ADD COLUMN IF NOT EXISTS escalated_at timestamp with time zone;

ALTER TABLE public.whatsapp_conversations 
ADD COLUMN IF NOT EXISTS last_message_at timestamp with time zone DEFAULT now();

-- 5. Add whatsapp_conversation_id to service_queue
ALTER TABLE public.service_queue 
ADD COLUMN IF NOT EXISTS whatsapp_conversation_id uuid REFERENCES public.whatsapp_conversations(id) ON DELETE SET NULL;

-- 6. Add conversation_id to service_messages if not exists
ALTER TABLE public.service_messages 
ADD COLUMN IF NOT EXISTS conversation_id uuid REFERENCES public.whatsapp_conversations(id) ON DELETE CASCADE;

-- =============================================
-- INDEXES
-- =============================================
CREATE INDEX IF NOT EXISTS idx_chatbot_nodes_flow_id ON public.chatbot_nodes(flow_id);
CREATE INDEX IF NOT EXISTS idx_chatbot_nodes_next_node_id ON public.chatbot_nodes(next_node_id);
CREATE INDEX IF NOT EXISTS idx_chatbot_node_options_node_id ON public.chatbot_node_options(node_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_conversations_current_node ON public.whatsapp_conversations(current_node_id);
CREATE INDEX IF NOT EXISTS idx_service_messages_conversation ON public.service_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_service_queue_whatsapp_conv ON public.service_queue(whatsapp_conversation_id);

-- =============================================
-- ROW LEVEL SECURITY
-- =============================================

-- Enable RLS
ALTER TABLE public.chatbot_flows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chatbot_nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chatbot_node_options ENABLE ROW LEVEL SECURITY;

-- Chatbot Flows policies
CREATE POLICY "Authenticated users can read chatbot flows"
  ON public.chatbot_flows FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage chatbot flows"
  ON public.chatbot_flows FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Anon can read flows (for edge functions)
CREATE POLICY "Anon can read chatbot flows"
  ON public.chatbot_flows FOR SELECT
  TO anon
  USING (true);

-- Chatbot Nodes policies
CREATE POLICY "Authenticated users can read chatbot nodes"
  ON public.chatbot_nodes FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage chatbot nodes"
  ON public.chatbot_nodes FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Anon can read chatbot nodes"
  ON public.chatbot_nodes FOR SELECT
  TO anon
  USING (true);

-- Chatbot Node Options policies
CREATE POLICY "Authenticated users can read node options"
  ON public.chatbot_node_options FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage node options"
  ON public.chatbot_node_options FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Anon can read node options"
  ON public.chatbot_node_options FOR SELECT
  TO anon
  USING (true);

-- =============================================
-- TRIGGERS FOR UPDATED_AT
-- =============================================

CREATE TRIGGER update_chatbot_flows_updated_at
  BEFORE UPDATE ON public.chatbot_flows
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_chatbot_nodes_updated_at
  BEFORE UPDATE ON public.chatbot_nodes
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();
-- -----------------------------------------------------------
-- Migration: 20260128175115_b10a930d-2cfe-46a2-a8f6-ff5fb0b7dd5a.sql
-- -----------------------------------------------------------
-- Força o PostgREST a recarregar o schema cache
NOTIFY pgrst, 'reload schema';

-- Garantir que as tabelas estão expostas corretamente com comentários
COMMENT ON TABLE public.chatbot_flows IS 'Fluxos de chatbot para atendimento automatizado';
COMMENT ON TABLE public.chatbot_nodes IS 'Nós da árvore de decisão do chatbot';
COMMENT ON TABLE public.chatbot_node_options IS 'Opções de menu para navegação no chatbot';
-- -----------------------------------------------------------
-- Migration: 20260128175349_28c8567c-2224-4531-abe8-97eedc9891c6.sql
-- -----------------------------------------------------------
-- Conceder permissões para as tabelas do chatbot
GRANT ALL ON public.chatbot_flows TO anon, authenticated, service_role;
GRANT ALL ON public.chatbot_nodes TO anon, authenticated, service_role;
GRANT ALL ON public.chatbot_node_options TO anon, authenticated, service_role;

-- Forçar reload do schema cache novamente
NOTIFY pgrst, 'reload schema';
-- -----------------------------------------------------------
-- Migration: 20260128182232_6d19e917-7d75-4ca5-bf6d-9678896f618f.sql
-- -----------------------------------------------------------
-- Add unique constraint on user_id if not exists, then insert admin user
DO $$
BEGIN
  -- Check if user already has a role
  IF EXISTS (SELECT 1 FROM user_roles WHERE user_id = '1801501f-f97f-4945-a0af-8a53ca33d36c') THEN
    UPDATE user_roles SET role = 'admin' WHERE user_id = '1801501f-f97f-4945-a0af-8a53ca33d36c';
  ELSE
    INSERT INTO user_roles (user_id, role) VALUES ('1801501f-f97f-4945-a0af-8a53ca33d36c', 'admin');
  END IF;
END $$;
-- -----------------------------------------------------------
-- Migration: 20260128205500_f7396493-8dd4-4421-8a94-f1cbfda2d32c.sql
-- -----------------------------------------------------------
-- =============================================
-- TABELAS DO CHATBOT (apenas as que faltam)
-- =============================================

-- chatbot_flows
CREATE TABLE IF NOT EXISTS public.chatbot_flows (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name text NOT NULL,
  description text,
  channel text NOT NULL DEFAULT 'all',
  is_active boolean NOT NULL DEFAULT true,
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- chatbot_nodes
CREATE TABLE IF NOT EXISTS public.chatbot_nodes (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  flow_id uuid NOT NULL REFERENCES public.chatbot_flows(id) ON DELETE CASCADE,
  node_type text NOT NULL,
  name text NOT NULL,
  content text,
  options jsonb,
  action_type text DEFAULT 'none',
  action_config jsonb,
  next_node_id uuid,
  node_order integer NOT NULL DEFAULT 0,
  is_entry_point boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- chatbot_node_options
CREATE TABLE IF NOT EXISTS public.chatbot_node_options (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  node_id uuid NOT NULL REFERENCES public.chatbot_nodes(id) ON DELETE CASCADE,
  option_key text NOT NULL,
  option_text text NOT NULL,
  next_node_id uuid,
  option_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- =============================================
-- CONSTRAINTS (IF NOT EXISTS não funciona, então uso DO block)
-- =============================================

DO $$ 
BEGIN
  -- Self-reference para chatbot_nodes.next_node_id
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chatbot_nodes_next_node_fk'
  ) THEN
    ALTER TABLE public.chatbot_nodes 
    ADD CONSTRAINT chatbot_nodes_next_node_fk 
    FOREIGN KEY (next_node_id) REFERENCES public.chatbot_nodes(id) ON DELETE SET NULL;
  END IF;

  -- FK para chatbot_node_options.next_node_id
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chatbot_node_options_next_node_id_fkey'
  ) THEN
    ALTER TABLE public.chatbot_node_options 
    ADD CONSTRAINT chatbot_node_options_next_node_id_fkey 
    FOREIGN KEY (next_node_id) REFERENCES public.chatbot_nodes(id) ON DELETE SET NULL;
  END IF;
END $$;

-- =============================================
-- ÍNDICES (IF NOT EXISTS)
-- =============================================

CREATE INDEX IF NOT EXISTS idx_chatbot_flows_active ON public.chatbot_flows(is_active);
CREATE INDEX IF NOT EXISTS idx_chatbot_flows_channel ON public.chatbot_flows(channel);
CREATE INDEX IF NOT EXISTS idx_chatbot_nodes_flow ON public.chatbot_nodes(flow_id);
CREATE INDEX IF NOT EXISTS idx_chatbot_nodes_entry ON public.chatbot_nodes(is_entry_point) WHERE is_entry_point = true;
CREATE INDEX IF NOT EXISTS idx_chatbot_node_options_node ON public.chatbot_node_options(node_id);

-- =============================================
-- RLS
-- =============================================

ALTER TABLE public.chatbot_flows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chatbot_nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chatbot_node_options ENABLE ROW LEVEL SECURITY;

-- =============================================
-- POLICIES (drop and recreate to avoid conflicts)
-- =============================================

DROP POLICY IF EXISTS "Authenticated users can view chatbot flows" ON public.chatbot_flows;
DROP POLICY IF EXISTS "Authenticated users can manage chatbot flows" ON public.chatbot_flows;
DROP POLICY IF EXISTS "Authenticated users can view chatbot nodes" ON public.chatbot_nodes;
DROP POLICY IF EXISTS "Authenticated users can manage chatbot nodes" ON public.chatbot_nodes;
DROP POLICY IF EXISTS "Authenticated users can view chatbot node options" ON public.chatbot_node_options;
DROP POLICY IF EXISTS "Authenticated users can manage chatbot node options" ON public.chatbot_node_options;

CREATE POLICY "Authenticated users can view chatbot flows" 
ON public.chatbot_flows FOR SELECT 
TO authenticated 
USING (true);

CREATE POLICY "Authenticated users can manage chatbot flows" 
ON public.chatbot_flows FOR ALL 
TO authenticated 
USING (true) 
WITH CHECK (true);

CREATE POLICY "Authenticated users can view chatbot nodes" 
ON public.chatbot_nodes FOR SELECT 
TO authenticated 
USING (true);

CREATE POLICY "Authenticated users can manage chatbot nodes" 
ON public.chatbot_nodes FOR ALL 
TO authenticated 
USING (true) 
WITH CHECK (true);

CREATE POLICY "Authenticated users can view chatbot node options" 
ON public.chatbot_node_options FOR SELECT 
TO authenticated 
USING (true);

CREATE POLICY "Authenticated users can manage chatbot node options" 
ON public.chatbot_node_options FOR ALL 
TO authenticated 
USING (true) 
WITH CHECK (true);

-- =============================================
-- TRIGGERS
-- =============================================

DROP TRIGGER IF EXISTS update_chatbot_flows_updated_at ON public.chatbot_flows;
DROP TRIGGER IF EXISTS update_chatbot_nodes_updated_at ON public.chatbot_nodes;

CREATE TRIGGER update_chatbot_flows_updated_at
BEFORE UPDATE ON public.chatbot_flows
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_chatbot_nodes_updated_at
BEFORE UPDATE ON public.chatbot_nodes
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
-- -----------------------------------------------------------
-- Migration: 20260209142832_89b40e6e-09ba-4415-8147-657812e63faa.sql
-- -----------------------------------------------------------

-- Add channel column to complaints to track origin (web form, voice agent, phone call)
ALTER TABLE public.complaints
ADD COLUMN channel text DEFAULT 'web';

-- Update existing voice-created complaints (those without explicit channel) 
-- No action needed - defaults to 'web' which is correct for existing data

-- -----------------------------------------------------------
-- Migration: 20260209165427_430a4122-5ba1-4d3f-ad46-f415e899ad78.sql
-- -----------------------------------------------------------

-- Tabela de auditoria para rastrear todas as alterações em solicitações
CREATE TABLE public.complaint_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  complaint_id UUID NOT NULL REFERENCES public.complaints(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  user_email TEXT,
  action TEXT NOT NULL, -- 'reclassified_type', 'reclassified_category', 'status_changed', 'assigned', 'workflow_changed', 'notes_updated'
  field_changed TEXT NOT NULL, -- nome do campo alterado
  old_value TEXT,
  new_value TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Índices para consultas rápidas
CREATE INDEX idx_complaint_audit_complaint_id ON public.complaint_audit_log(complaint_id);
CREATE INDEX idx_complaint_audit_created_at ON public.complaint_audit_log(created_at DESC);

-- Enable RLS
ALTER TABLE public.complaint_audit_log ENABLE ROW LEVEL SECURITY;

-- Política: usuários autenticados podem inserir logs
CREATE POLICY "Authenticated users can insert audit logs"
ON public.complaint_audit_log FOR INSERT
TO authenticated
WITH CHECK (true);

-- Política: usuários autenticados podem ver logs
CREATE POLICY "Authenticated users can view audit logs"
ON public.complaint_audit_log FOR SELECT
TO authenticated
USING (true);

-- Adicionar coluna workflow_id na tabela complaints se não existir
ALTER TABLE public.complaints ADD COLUMN IF NOT EXISTS workflow_id UUID REFERENCES public.workflows(id) ON DELETE SET NULL;

-- -----------------------------------------------------------
-- Migration: 20260209170449_b37e1458-9ff9-4dde-a79f-413de09c78ca.sql
-- -----------------------------------------------------------

-- Add AI triage column to store pre-analysis data (sentiment + scenario)
ALTER TABLE public.complaints
ADD COLUMN IF NOT EXISTS ai_triage JSONB DEFAULT NULL;

COMMENT ON COLUMN public.complaints.ai_triage IS 'AI pre-analysis: sentiment, scenario summary, urgency level';

-- -----------------------------------------------------------
-- Migration: 20260210122904_520e79bb-b97c-425a-9bbf-3c1bed87fd10.sql
-- -----------------------------------------------------------

-- Link existing service_queue items to their complaints
UPDATE public.service_queue 
SET complaint_id = '0e2080ef-841e-468b-b23f-c3be7f1b4107'
WHERE id = '1f29a9b7-54dd-45f0-a2bc-9631956dd167' AND complaint_id IS NULL;

UPDATE public.service_queue 
SET complaint_id = '7ca08094-8705-45bb-bfd7-c4f9ba311041'
WHERE id = 'b92e9348-1ab7-4cfb-9334-3962e990c72e' AND complaint_id IS NULL;

-- -----------------------------------------------------------
-- Migration: 20260210203312_79d4b314-0986-47fc-a7ef-3264ca004ffa.sql
-- -----------------------------------------------------------

-- Tabela de campanhas
CREATE TABLE public.campaigns (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  channel TEXT NOT NULL CHECK (channel IN ('email', 'sms', 'whatsapp')),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'scheduled', 'active', 'paused', 'completed', 'failed')),
  subject TEXT, -- para email
  content TEXT NOT NULL,
  recipients JSONB NOT NULL DEFAULT '[]'::jsonb, -- array de {name, email, phone}
  total_recipients INTEGER NOT NULL DEFAULT 0,
  delivered INTEGER NOT NULL DEFAULT 0,
  opened INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  scheduled_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;

-- Policies - authenticated users can manage campaigns
CREATE POLICY "Authenticated users can view campaigns"
  ON public.campaigns FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can create campaigns"
  ON public.campaigns FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can update campaigns"
  ON public.campaigns FOR UPDATE
  USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can delete campaigns"
  ON public.campaigns FOR DELETE
  USING (auth.role() = 'authenticated');

-- Trigger para updated_at
CREATE TRIGGER update_campaigns_updated_at
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Tabela de log de envios individuais
CREATE TABLE public.campaign_sends (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  campaign_id UUID NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  recipient_name TEXT,
  recipient_contact TEXT NOT NULL, -- email ou telefone
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'delivered', 'opened', 'failed')),
  error_message TEXT,
  sent_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  opened_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.campaign_sends ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view campaign sends"
  ON public.campaign_sends FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can insert campaign sends"
  ON public.campaign_sends FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can update campaign sends"
  ON public.campaign_sends FOR UPDATE
  USING (auth.role() = 'authenticated');

-- -----------------------------------------------------------
-- Migration: 20260210203830_d6952889-a66c-4931-9f95-379a43372986.sql
-- -----------------------------------------------------------

-- Enable pg_cron and pg_net extensions
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- Grant usage to postgres role
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

-- -----------------------------------------------------------
-- Migration: 20260210204224_bca8e0ca-d430-4b3f-b493-ae50d0b54ec1.sql
-- -----------------------------------------------------------
NOTIFY pgrst, 'reload schema';
-- -----------------------------------------------------------
-- Migration: 20260210204856_bc4150b5-c857-48bf-8526-5217c71a6101.sql
-- -----------------------------------------------------------

-- Function to log complaint changes to audit log
CREATE OR REPLACE FUNCTION public.log_complaint_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Status change
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'status_change', 'status', OLD.status, NEW.status, auth.uid(), 
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  -- Assignment change
  IF OLD.assigned_to IS DISTINCT FROM NEW.assigned_to THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'assignment', 'assigned_to', OLD.assigned_to, NEW.assigned_to, auth.uid(),
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  -- Workflow change
  IF OLD.workflow_id IS DISTINCT FROM NEW.workflow_id THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'workflow_change', 'workflow_id', OLD.workflow_id::text, NEW.workflow_id::text, auth.uid(),
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  -- Workflow step advance
  IF OLD.current_workflow_step_id IS DISTINCT FROM NEW.current_workflow_step_id THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'workflow_step_advance', 'current_workflow_step_id', OLD.current_workflow_step_id::text, NEW.current_workflow_step_id::text, auth.uid(),
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  -- Internal notes change
  IF OLD.internal_notes IS DISTINCT FROM NEW.internal_notes THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'note_added', 'internal_notes', NULL, NEW.internal_notes, auth.uid(),
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  -- Category change
  IF OLD.category IS DISTINCT FROM NEW.category THEN
    INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
    VALUES (NEW.id, 'field_update', 'category', OLD.category, NEW.category, auth.uid(),
      (SELECT email FROM auth.users WHERE id = auth.uid()));
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger on complaints UPDATE
CREATE TRIGGER trg_complaint_audit_log
  AFTER UPDATE ON public.complaints
  FOR EACH ROW
  EXECUTE FUNCTION public.log_complaint_activity();

-- Also log new complaint creation
CREATE OR REPLACE FUNCTION public.log_complaint_creation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO complaint_audit_log (complaint_id, action, field_changed, old_value, new_value, user_id, user_email)
  VALUES (NEW.id, 'created', 'status', NULL, NEW.status, auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()));
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_complaint_creation_log
  AFTER INSERT ON public.complaints
  FOR EACH ROW
  EXECUTE FUNCTION public.log_complaint_creation();

-- -----------------------------------------------------------
-- Migration: 20260211142627_d0687bdd-2524-4861-b2ff-c1db927fc781.sql
-- -----------------------------------------------------------

-- Tabela de configurações de SLA
CREATE TABLE public.sla_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_key text NOT NULL UNIQUE,
  metric_label text NOT NULL,
  target_value numeric NOT NULL,
  unit text NOT NULL DEFAULT 'minutes',
  warning_threshold numeric,
  critical_threshold numeric,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.sla_settings ENABLE ROW LEVEL SECURITY;

-- Apenas admins podem gerenciar SLAs
CREATE POLICY "Admins can manage SLA settings"
ON public.sla_settings
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Todos autenticados podem ler SLAs
CREATE POLICY "Authenticated users can read SLA settings"
ON public.sla_settings
FOR SELECT
TO authenticated
USING (true);

-- Trigger para updated_at
CREATE TRIGGER update_sla_settings_updated_at
BEFORE UPDATE ON public.sla_settings
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Inserir SLAs padrão
INSERT INTO public.sla_settings (metric_key, metric_label, target_value, unit, warning_threshold, critical_threshold) VALUES
  ('tma', 'Tempo Médio de Atendimento (TMA)', 10, 'minutes', 8, 12),
  ('tme', 'Tempo Médio de Espera (TME)', 3, 'minutes', 2, 5),
  ('frt', 'Tempo de Primeira Resposta (FRT)', 1, 'minutes', 0.5, 2),
  ('fcr', 'Resolução no Primeiro Contato (FCR)', 80, 'percent', 85, 70),
  ('csat', 'Satisfação do Cliente (CSAT)', 85, 'percent', 90, 75),
  ('nps', 'Net Promoter Score (NPS)', 50, 'score', 60, 30),
  ('abandono', 'Taxa de Abandono', 5, 'percent', 3, 10),
  ('countdown_seconds', 'Tempo de Contagem Regressiva', 10, 'seconds', null, null);

-- -----------------------------------------------------------
-- Migration: 20260211144556_e4a23105-b8d6-4771-aef7-1f8f98c949d7.sql
-- -----------------------------------------------------------

-- Tabela de respostas NPS
CREATE TABLE public.nps_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  complaint_id uuid REFERENCES public.complaints(id) ON DELETE SET NULL,
  session_id uuid REFERENCES public.service_sessions(id) ON DELETE SET NULL,
  score integer NOT NULL CHECK (score >= 0 AND score <= 10),
  comment text,
  channel text DEFAULT 'web',
  respondent_name text,
  respondent_email text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.nps_responses ENABLE ROW LEVEL SECURITY;

-- Inserção pública (usuários anônimos podem responder)
CREATE POLICY "Anyone can insert NPS responses"
ON public.nps_responses
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Leitura apenas para autenticados
CREATE POLICY "Authenticated users can read NPS"
ON public.nps_responses
FOR SELECT
TO authenticated
USING (true);

-- -----------------------------------------------------------
-- Migration: 20260211145457_56a5fac5-ef5c-4b38-85b7-5d21f93a3dea.sql
-- -----------------------------------------------------------
-- Add notification toggle settings to sla_settings
INSERT INTO public.sla_settings (metric_key, metric_label, target_value, unit, is_active)
VALUES 
  ('notif_sms_enabled', 'Envio automático de SMS ao registrar', 1, 'boolean', true),
  ('notif_email_enabled', 'Envio automático de E-mail ao registrar', 1, 'boolean', true)
ON CONFLICT DO NOTHING;
-- -----------------------------------------------------------
-- Migration: 20260211145938_a5033f01-834e-4c90-8385-d72e340988a3.sql
-- -----------------------------------------------------------
-- Add last_assigned_at for round-robin tracking
ALTER TABLE public.attendant_profiles 
ADD COLUMN IF NOT EXISTS last_assigned_at timestamptz DEFAULT '2000-01-01';

-- Create index for efficient online attendant lookup
CREATE INDEX IF NOT EXISTS idx_attendant_profiles_status 
ON public.attendant_profiles (status, last_assigned_at);
-- -----------------------------------------------------------
-- Migration: 20260211152125_816e546c-4744-4b50-ad7b-1bdf3b30ba70.sql
-- -----------------------------------------------------------

-- 1. service_queue table
CREATE TABLE IF NOT EXISTS public.service_queue (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'web',
  status TEXT NOT NULL DEFAULT 'waiting',
  priority INTEGER NOT NULL DEFAULT 3,
  customer_name TEXT,
  customer_email TEXT,
  customer_phone TEXT,
  customer_avatar TEXT,
  subject TEXT,
  last_message TEXT,
  unread_count INTEGER NOT NULL DEFAULT 1,
  complaint_id UUID,
  voice_session_id TEXT,
  assigned_to UUID,
  waiting_since TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.service_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view queue" ON public.service_queue FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Authenticated users can insert to queue" ON public.service_queue FOR INSERT WITH CHECK (true);
CREATE POLICY "Authenticated users can update queue" ON public.service_queue FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admins can delete from queue" ON public.service_queue FOR DELETE USING (has_role(auth.uid(), 'admin'::app_role));

-- 2. complaint_audit_log table
CREATE TABLE IF NOT EXISTS public.complaint_audit_log (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  complaint_id UUID NOT NULL REFERENCES public.complaints(id) ON DELETE CASCADE,
  user_id UUID,
  action TEXT NOT NULL,
  field_changed TEXT,
  old_value TEXT,
  new_value TEXT,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.complaint_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage audit log" ON public.complaint_audit_log FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Attendants can view audit log" ON public.complaint_audit_log FOR SELECT USING (has_role(auth.uid(), 'atendente'::app_role));
CREATE POLICY "Authenticated can insert audit log" ON public.complaint_audit_log FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- 3. Add last_assigned_at to attendant_profiles
ALTER TABLE public.attendant_profiles ADD COLUMN IF NOT EXISTS last_assigned_at TIMESTAMP WITH TIME ZONE DEFAULT now();

-- 4. Add ai_triage to complaints
ALTER TABLE public.complaints ADD COLUMN IF NOT EXISTS ai_triage JSONB;

-- 5. chatbot_flows table
CREATE TABLE IF NOT EXISTS public.chatbot_flows (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL DEFAULT 'Novo Fluxo',
  description TEXT,
  channel TEXT NOT NULL DEFAULT 'all',
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.chatbot_flows ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage chatbot_flows" ON public.chatbot_flows FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Public can read active flows" ON public.chatbot_flows FOR SELECT USING (is_active = true);

-- 6. chatbot_nodes table
CREATE TABLE IF NOT EXISTS public.chatbot_nodes (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  flow_id UUID NOT NULL REFERENCES public.chatbot_flows(id) ON DELETE CASCADE,
  node_type TEXT NOT NULL DEFAULT 'message',
  name TEXT NOT NULL DEFAULT 'Novo Nó',
  content TEXT,
  options JSONB,
  action_type TEXT DEFAULT 'none',
  action_config JSONB,
  next_node_id UUID,
  node_order INTEGER NOT NULL DEFAULT 0,
  is_entry_point BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.chatbot_nodes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage chatbot_nodes" ON public.chatbot_nodes FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Public can read active nodes" ON public.chatbot_nodes FOR SELECT USING (is_active = true);

-- 7. chatbot_node_options table
CREATE TABLE IF NOT EXISTS public.chatbot_node_options (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  node_id UUID NOT NULL REFERENCES public.chatbot_nodes(id) ON DELETE CASCADE,
  option_key TEXT NOT NULL DEFAULT '1',
  option_text TEXT NOT NULL DEFAULT 'Nova Opção',
  next_node_id UUID,
  option_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.chatbot_node_options ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage chatbot_node_options" ON public.chatbot_node_options FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Public can read node options" ON public.chatbot_node_options FOR SELECT USING (true);

-- 8. whatsapp_conversations table
CREATE TABLE IF NOT EXISTS public.whatsapp_conversations (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  phone_number TEXT NOT NULL,
  contact_name TEXT,
  current_flow_id UUID REFERENCES public.chatbot_flows(id),
  current_node_id UUID REFERENCES public.chatbot_nodes(id),
  session_data JSONB DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'active',
  last_message_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
ALTER TABLE public.whatsapp_conversations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage whatsapp_conversations" ON public.whatsapp_conversations FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Attendants can view whatsapp_conversations" ON public.whatsapp_conversations FOR SELECT USING (has_role(auth.uid(), 'atendente'::app_role));

-- Triggers for updated_at
CREATE TRIGGER update_service_queue_updated_at BEFORE UPDATE ON public.service_queue FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_chatbot_flows_updated_at BEFORE UPDATE ON public.chatbot_flows FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_chatbot_nodes_updated_at BEFORE UPDATE ON public.chatbot_nodes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_whatsapp_conversations_updated_at BEFORE UPDATE ON public.whatsapp_conversations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Notify PostgREST to reload schema
NOTIFY pgrst, 'reload schema';

-- -----------------------------------------------------------
-- Migration: 20260211152155_dfd4097e-1284-4a2d-9388-f23dc9dbeb44.sql
-- -----------------------------------------------------------

-- Fix overly permissive INSERT policy on service_queue
DROP POLICY IF EXISTS "Authenticated users can insert to queue" ON public.service_queue;
CREATE POLICY "Authenticated users can insert to queue" ON public.service_queue FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Fix overly permissive INSERT policy on complaint_audit_log  
DROP POLICY IF EXISTS "Authenticated can insert audit log" ON public.complaint_audit_log;
CREATE POLICY "Authenticated can insert audit log" ON public.complaint_audit_log FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- -----------------------------------------------------------
-- Migration: 20260211152244_1037f78f-7c5d-47e4-8a95-ccee75ec1313.sql
-- -----------------------------------------------------------
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins can manage admin_users" ON public.admin_users FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "Users can view own admin record" ON public.admin_users FOR SELECT USING (user_id = auth.uid());

-- -----------------------------------------------------------
-- Migration: 20260211153255_5683e20d-b52d-4964-9747-df585201fcce.sql
-- -----------------------------------------------------------

-- Drop old constraint
ALTER TABLE public.complaints DROP CONSTRAINT IF EXISTS complaints_status_check;

-- Add new constraint with Portuguese slugs matching the code
ALTER TABLE public.complaints ADD CONSTRAINT complaints_status_check 
  CHECK (status = ANY (ARRAY['novo', 'em_analise', 'resolvido', 'fechado', 'pending', 'in_progress', 'resolved', 'closed']));

-- Update existing records from English to Portuguese
UPDATE public.complaints SET status = 'novo' WHERE status = 'pending';
UPDATE public.complaints SET status = 'em_analise' WHERE status = 'in_progress';
UPDATE public.complaints SET status = 'resolvido' WHERE status = 'resolved';
UPDATE public.complaints SET status = 'fechado' WHERE status = 'closed';

-- Update default
ALTER TABLE public.complaints ALTER COLUMN status SET DEFAULT 'novo';

-- -----------------------------------------------------------
-- Migration: 20260211153950_dd6b699b-f343-45dc-8f6e-4748eba571d0.sql
-- -----------------------------------------------------------

ALTER TABLE public.complaints 
  ADD COLUMN IF NOT EXISTS first_viewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS first_viewed_by UUID;

ALTER TABLE public.complaints DROP CONSTRAINT IF EXISTS complaints_status_check;
ALTER TABLE public.complaints ADD CONSTRAINT complaints_status_check 
  CHECK (status = ANY (ARRAY[
    'novo', 'visualizado', 'em_analise', 'resolvido', 'fechado',
    'pending', 'in_progress', 'resolved', 'closed'
  ]));

-- Allow attendants to update any complaint with status 'novo' (for auto-marking as viewed)
CREATE POLICY "Attendants can mark novo complaints as viewed"
  ON public.complaints FOR UPDATE
  USING (has_role(auth.uid(), 'atendente'::app_role) AND status = 'novo')
  WITH CHECK (has_role(auth.uid(), 'atendente'::app_role));

-- -----------------------------------------------------------
-- Migration: 20260211154610_e754441e-0f76-48f6-a0e2-a7676ba979af.sql
-- -----------------------------------------------------------

-- Fix login loop: ensure the attendant user has an assigned role
INSERT INTO public.user_roles (user_id, role)
VALUES ('081aaa4b-386e-426a-8383-cd5334eef380', 'atendente'::public.app_role)
ON CONFLICT (user_id, role) DO NOTHING;

-- -----------------------------------------------------------
-- Migration: 20260219145352_1775e18e-f520-4ecf-a8ab-e9cb2ef04a5a.sql
-- -----------------------------------------------------------
-- Drop the restrictive INSERT policy on service_messages
DROP POLICY IF EXISTS "Usuarios podem criar mensagens em suas sessoes" ON public.service_messages;

-- Create a more permissive INSERT policy that allows:
-- 1. Authenticated users (attendants) to insert into their active sessions
-- 2. Any user (including anon from chatbot) to insert bot/customer messages
CREATE POLICY "Allow inserting service messages"
ON public.service_messages
FOR INSERT
WITH CHECK (
  -- Authenticated attendants can insert into their sessions
  (EXISTS (
    SELECT 1 FROM service_sessions
    WHERE service_sessions.id = service_messages.session_id
    AND service_sessions.attendant_id = auth.uid()
    AND service_sessions.status = 'active'
  ))
  OR
  -- Allow bot and customer messages from anyone (for chatbot transfers)
  (sender_type IN ('bot', 'customer'))
);

-- Also update SELECT policy so attendants can see messages from conversations they take over
DROP POLICY IF EXISTS "Usuarios podem ver mensagens de suas sessoes" ON public.service_messages;

CREATE POLICY "Users can view service messages"
ON public.service_messages
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM service_sessions
    WHERE service_sessions.id = service_messages.session_id
    AND (service_sessions.attendant_id = auth.uid() OR check_admin_access())
  )
  OR
  -- Allow reading messages by session_id if the user is authenticated
  (auth.role() = 'authenticated')
);
-- -----------------------------------------------------------
-- Migration: 20260219180424_20554022-961d-466d-a3ca-4e5594627a1d.sql
-- -----------------------------------------------------------

-- Table to store connected email accounts (SMTP or OAuth)
CREATE TABLE public.email_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  account_type text NOT NULL DEFAULT 'smtp', -- 'smtp', 'gmail_oauth', 'outlook_oauth'
  email_address text NOT NULL,
  display_name text,
  -- SMTP fields (encrypted at rest by Supabase)
  smtp_host text,
  smtp_port integer DEFAULT 587,
  smtp_user text,
  smtp_password text,
  imap_host text,
  imap_port integer DEFAULT 993,
  -- OAuth fields
  oauth_access_token text,
  oauth_refresh_token text,
  oauth_token_expires_at timestamp with time zone,
  oauth_provider_data jsonb DEFAULT '{}'::jsonb,
  -- Status
  is_active boolean DEFAULT true,
  is_default boolean DEFAULT false,
  last_poll_at timestamp with time zone,
  last_poll_error text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now()
);

ALTER TABLE public.email_accounts ENABLE ROW LEVEL SECURITY;

-- Users can manage their own email accounts
CREATE POLICY "Users can manage own email accounts"
  ON public.email_accounts FOR ALL
  USING (user_id = auth.uid());

-- Admins can view all email accounts  
CREATE POLICY "Admins can view all email accounts"
  ON public.email_accounts FOR SELECT
  USING (has_role(auth.uid(), 'admin'::app_role));

-- Table to store email messages linked to complaints
CREATE TABLE public.email_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  complaint_id uuid NOT NULL REFERENCES public.complaints(id) ON DELETE CASCADE,
  email_account_id uuid REFERENCES public.email_accounts(id) ON DELETE SET NULL,
  message_id text, -- RFC 822 Message-ID for threading
  in_reply_to text, -- For threading
  thread_id text, -- Gmail/Outlook thread ID
  direction text NOT NULL DEFAULT 'outbound', -- 'outbound' or 'inbound'
  from_address text NOT NULL,
  to_addresses text[] NOT NULL,
  cc_addresses text[],
  subject text NOT NULL,
  body_text text,
  body_html text,
  sent_at timestamp with time zone DEFAULT now(),
  read_at timestamp with time zone,
  status text DEFAULT 'sent', -- 'draft', 'sending', 'sent', 'failed', 'received'
  error_message text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now()
);

ALTER TABLE public.email_messages ENABLE ROW LEVEL SECURITY;

-- Authenticated users can view email messages for complaints they can access
CREATE POLICY "Authenticated can view email messages"
  ON public.email_messages FOR SELECT
  USING (auth.role() = 'authenticated');

-- Authenticated users can insert email messages
CREATE POLICY "Authenticated can insert email messages"
  ON public.email_messages FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- Create indexes for performance
CREATE INDEX idx_email_messages_complaint_id ON public.email_messages(complaint_id);
CREATE INDEX idx_email_messages_thread_id ON public.email_messages(thread_id);
CREATE INDEX idx_email_messages_message_id ON public.email_messages(message_id);
CREATE INDEX idx_email_accounts_user_id ON public.email_accounts(user_id);

-- Trigger for updated_at on email_accounts
CREATE TRIGGER update_email_accounts_updated_at
  BEFORE UPDATE ON public.email_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- -----------------------------------------------------------
-- Migration: 20260219190100_bc9614a2-3e6d-4c53-b5a4-9910ebd77303.sql
-- -----------------------------------------------------------

-- Tabela para armazenar avaliações NPS dos atendimentos
CREATE TABLE public.nps_responses (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  score INTEGER NOT NULL CHECK (score >= 0 AND score <= 10),
  comment TEXT,
  complaint_id UUID REFERENCES public.complaints(id),
  session_id UUID REFERENCES public.service_sessions(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.nps_responses ENABLE ROW LEVEL SECURITY;

-- Anyone can submit a rating (public form)
CREATE POLICY "Anyone can insert nps responses"
  ON public.nps_responses
  FOR INSERT
  WITH CHECK (true);

-- Authenticated users can view ratings
CREATE POLICY "Authenticated can view nps responses"
  ON public.nps_responses
  FOR SELECT
  USING (auth.role() = 'authenticated');

