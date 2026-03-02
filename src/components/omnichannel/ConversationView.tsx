import { useState, useEffect, useRef, useCallback, useMemo, ChangeEvent } from "react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import {
  Paperclip,
  Send,
  PanelRight,
  Smile,
  Loader2,
  Bot,
  User,
  Headset,
  Info,
  ArrowRightLeft,
  Eye,
  CheckCircle,
  UserPlus,
  GitBranch,
  FileIcon,
  Image as ImageIcon,
  Download,
  X,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { ConversationToolbar } from "./ConversationToolbar";
import { QuickMessagesPanel } from "./QuickMessagesPanel";
import { ForwardModal } from "./ForwardModal";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import { useServiceQueue } from "@/hooks/useServiceQueue";
import { ScrollArea } from "@/components/ui/scroll-area";


// Format audit log events into readable messages
function formatAuditEvent(log: any): string {
  const actionMap: Record<string, string> = {
    viewed: "📋 Solicitação visualizada",
    status_change: "🔄 Status alterado",
    assigned: "👤 Atribuído",
    forwarded: "➡️ Encaminhado",
    reclassified: "🏷️ Reclassificado",
    workflow_assigned: "⚙️ Fluxo de trabalho atribuído",
    workflow_advanced: "⏩ Fluxo avançou de etapa",
    resolved: "✅ Solicitação resolvida",
    created: "📝 Solicitação criada",
  };

  const label = actionMap[log.action] || `📌 ${log.action}`;

  if (log.field_changed && log.old_value && log.new_value) {
    return `${label}\n${log.field_changed}: ${log.old_value} → ${log.new_value}${log.notes ? `\n💬 ${log.notes}` : ""}`;
  }

  if (log.field_changed && log.new_value) {
    return `${label}\n${log.field_changed}: ${log.new_value}${log.notes ? `\n💬 ${log.notes}` : ""}`;
  }

  if (log.notes) {
    return `${label}\n💬 ${log.notes}`;
  }

  return label;
}

type TimelineEntry = {
  id: string;
  content: string;
  sender_type: "customer" | "bot" | "agent" | "system";
  created_at: string;
  metadata?: {
    action?: string;
    field_changed?: string;
    old_value?: string | null;
    new_value?: string | null;
  };
};

type ToolbarMode = "chat" | "documents" | "quick-messages";

type ConversationViewProps = {
  conversationId: string;
  onForward?: (stepId: string, notes: string, summary?: string, complaintType?: string) => Promise<boolean>;
  onEndSession?: () => void;
  hasActiveSession?: boolean;
};

export function ConversationView({
  conversationId,
  onForward,
  onEndSession,
  hasActiveSession = false,
}: ConversationViewProps) {
  const [newMessage, setNewMessage] = useState("");
  const [activeMode, setActiveMode] = useState<ToolbarMode>("chat");
  const [showForwardModal, setShowForwardModal] = useState(false);
  const [messages, setMessages] = useState<TimelineEntry[]>([]);
  const [auditEvents, setAuditEvents] = useState<TimelineEntry[]>([]);
  const [isLoadingMessages, setIsLoadingMessages] = useState(true);
  const [isSending, setIsSending] = useState(false);
  const [isUploading, setIsUploading] = useState(false);
  const [pendingFile, setPendingFile] = useState<{ file: File; previewUrl: string | null } | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Get queue item data for customer info
  const { data: queueItems = [] } = useServiceQueue({ excludeCompleted: true });
  const queueItem = queueItems.find(item => item.id === conversationId);

  // Load messages for this conversation
  const loadMessages = useCallback(async () => {
    if (!conversationId) return;

    try {
      // For WhatsApp conversations, load messages by whatsapp conversation_id
      if (queueItem?.channel === 'whatsapp' && queueItem?.whatsapp_conversation_id) {
        const { data: waMsgs } = await supabase
          .from("service_messages")
          .select("*")
          .eq("conversation_id", queueItem.whatsapp_conversation_id)
          .order("created_at", { ascending: true });

        setMessages((waMsgs || []).map(m => ({
          id: m.id,
          content: m.content,
          sender_type: m.sender_type as TimelineEntry["sender_type"],
          created_at: m.created_at,
        })));
        setIsLoadingMessages(false);
        return;
      }

      // Try loading from service_messages using conversation_id reference
      // Messages are stored with session_id pointing to either a service_session or queue item
      const { data: sessionData } = await supabase
        .from("service_sessions")
        .select("id")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      if (sessionData?.id) {
        const { data: msgs } = await supabase
          .from("service_messages")
          .select("*")
          .eq("session_id", sessionData.id)
          .order("created_at", { ascending: true });
        
        if (msgs && msgs.length > 0) {
          setMessages(msgs.map(m => ({
            id: m.id,
            content: m.content,
            sender_type: m.sender_type as TimelineEntry["sender_type"],
            created_at: m.created_at,
          })));
          setIsLoadingMessages(false);
          return;
        }
      }

      // Fallback: check if there's a complaint with chat history in the metadata
      // or load messages linked directly to this queue item ID as session_id
      // (from the chatbot transfer flow)
      const { data: directMsgs } = await supabase
        .from("service_messages")
        .select("*")
        .eq("session_id", conversationId)
        .order("created_at", { ascending: true });

      if (directMsgs && directMsgs.length > 0) {
        setMessages(directMsgs.map(m => ({
          id: m.id,
          content: m.content,
          sender_type: m.sender_type as TimelineEntry["sender_type"],
          created_at: m.created_at,
        })));
      } else {
        setMessages([]);
      }
    } catch (error) {
      console.error("Error loading messages:", error);
      setMessages([]);
    } finally {
      setIsLoadingMessages(false);
    }
  }, [conversationId]);

  // Load audit log events for linked complaint
  const loadAuditEvents = useCallback(async () => {
    const complaintId = queueItem?.complaint_id;
    if (!complaintId) {
      setAuditEvents([]);
      return;
    }

    try {
      const { data: auditLogs } = await supabase
        .from("complaint_audit_log")
        .select("*")
        .eq("complaint_id", complaintId)
        .order("created_at", { ascending: true });

      if (auditLogs && auditLogs.length > 0) {
        setAuditEvents(auditLogs.map(log => ({
          id: `audit-${log.id}`,
          content: formatAuditEvent(log),
          sender_type: "system" as const,
          created_at: log.created_at,
          metadata: {
            action: log.action,
            field_changed: log.field_changed || undefined,
            old_value: log.old_value,
            new_value: log.new_value,
          },
        })));
      } else {
        setAuditEvents([]);
      }
    } catch (error) {
      console.error("Error loading audit log:", error);
    }
  }, [queueItem?.complaint_id]);

  useEffect(() => {
    setIsLoadingMessages(true);
    loadMessages();
    loadAuditEvents();
  }, [loadMessages, loadAuditEvents]);

  // Merge messages and audit events chronologically
  const timeline = useMemo(() => {
    const all = [...messages, ...auditEvents];
    return all.sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());
  }, [messages, auditEvents]);

  // Subscribe to new messages in real-time
  useEffect(() => {
    if (!conversationId) return;

    const channels: ReturnType<typeof supabase.channel>[] = [];

    // Messages channel — filter by whatsapp conversation_id or unfiltered for session-based
    const isWhatsapp = queueItem?.channel === 'whatsapp' && queueItem?.whatsapp_conversation_id;
    const msgChannelConfig = isWhatsapp
      ? {
          event: "INSERT" as const,
          schema: "public",
          table: "service_messages",
          filter: `conversation_id=eq.${queueItem.whatsapp_conversation_id}`,
        }
      : {
          event: "INSERT" as const,
          schema: "public",
          table: "service_messages",
        };

    const msgChannel = supabase
      .channel(`messages-${conversationId}`)
      .on("postgres_changes", msgChannelConfig, (payload) => {
          const newMsg = payload.new as any;
          setMessages(prev => {
            if (prev.some(m => m.id === newMsg.id)) return prev;
            return [...prev, {
              id: newMsg.id,
              content: newMsg.content,
              sender_type: newMsg.sender_type,
              created_at: newMsg.created_at,
            }];
          });
        }
      )
      .subscribe();
    channels.push(msgChannel);

    // Audit log channel (if complaint linked)
    if (queueItem?.complaint_id) {
      const auditChannel = supabase
        .channel(`audit-${queueItem.complaint_id}`)
        .on(
          "postgres_changes",
          {
            event: "INSERT",
            schema: "public",
            table: "complaint_audit_log",
            filter: `complaint_id=eq.${queueItem.complaint_id}`,
          },
          (payload) => {
            const log = payload.new as any;
            setAuditEvents(prev => {
              const id = `audit-${log.id}`;
              if (prev.some(e => e.id === id)) return prev;
              return [...prev, {
                id,
                content: formatAuditEvent(log),
                sender_type: "system" as const,
                created_at: log.created_at,
                metadata: {
                  action: log.action,
                  field_changed: log.field_changed || undefined,
                  old_value: log.old_value,
                  new_value: log.new_value,
                },
              }];
            });
          }
        )
        .subscribe();
      channels.push(auditChannel);
    }

    return () => {
      channels.forEach(ch => supabase.removeChannel(ch));
    };
  }, [conversationId, queueItem?.complaint_id, queueItem?.channel, queueItem?.whatsapp_conversation_id]);

  // Auto-scroll to bottom
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [timeline]);

  const handleSend = async () => {
    if (!newMessage.trim() || isSending) return;

    const content = newMessage.trim();
    setNewMessage("");
    setIsSending(true);

    try {
      // WhatsApp channel: send via Evolution API through whatsapp-send edge function
      if (queueItem?.channel === 'whatsapp' && queueItem?.whatsapp_conversation_id) {
        const { data: { user } } = await supabase.auth.getUser();
        const { error: waError } = await supabase.functions.invoke('whatsapp-send', {
          body: {
            conversationId: queueItem.whatsapp_conversation_id,
            text: content,
            agentName: user?.user_metadata?.full_name || 'Atendente',
          },
        });

        if (waError) {
          console.error("Error sending WhatsApp message:", waError);
          toast.error("Erro ao enviar mensagem pelo WhatsApp.");
          setNewMessage(content);
          return;
        }

        await supabase
          .from("service_queue")
          .update({ last_message: content, status: "in_progress" })
          .eq("id", conversationId);

        // Optimistically add to local state (realtime will also fire via subscription)
        setMessages(prev => [...prev, {
          id: crypto.randomUUID(),
          content,
          sender_type: "agent",
          created_at: new Date().toISOString(),
        }]);
        return;
      }

      // Other channels: save directly to service_messages
      let sessionId: string | null = null;

      const { data: existingSession } = await supabase
        .from("service_sessions")
        .select("id")
        .eq("conversation_id", conversationId)
        .eq("status", "active")
        .maybeSingle();

      sessionId = existingSession?.id || null;

      if (!sessionId) {
        // Create a new session
        const { data: { user } } = await supabase.auth.getUser();
        if (!user) {
          toast.error("Você precisa estar autenticado para enviar mensagens.");
          return;
        }

        const { data: newSession, error: sessionError } = await supabase
          .from("service_sessions")
          .insert({
            conversation_id: conversationId,
            attendant_id: user.id,
            complaint_id: queueItem?.complaint_id || null,
            status: "active",
          })
          .select()
          .single();

        if (sessionError) {
          console.error("Error creating session:", sessionError);
          toast.error("Erro ao criar sessão de atendimento.");
          return;
        }

        sessionId = newSession.id;
      }

      // Insert the message
      const { error: msgError } = await supabase
        .from("service_messages")
        .insert({
          session_id: sessionId,
          sender_type: "agent",
          content,
        });

      if (msgError) {
        console.error("Error sending message:", msgError);
        toast.error("Erro ao enviar mensagem.");
        return;
      }

      // Update queue item
      await supabase
        .from("service_queue")
        .update({
          last_message: content,
          status: "in_progress",
        })
        .eq("id", conversationId);

      // Optimistically add to local state (realtime will also fire)
      setMessages(prev => [...prev, {
        id: crypto.randomUUID(),
        content,
        sender_type: "agent",
        created_at: new Date().toISOString(),
      }]);
    } catch (error) {
      console.error("Error sending message:", error);
      toast.error("Erro ao enviar mensagem.");
    } finally {
      setIsSending(false);
    }
  };

  const handleInsertQuickMessage = (content: string) => {
    setNewMessage((prev) => {
      if (prev.trim()) {
        return prev + "\n" + content;
      }
      return content;
    });
    setActiveMode("chat");
    toast.success("Mensagem inserida");
  };

  // File upload handler
  const handleFileSelect = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) {
      toast.error("Arquivo muito grande. Máximo: 10MB");
      return;
    }
    const isImage = file.type.startsWith("image/");
    const previewUrl = isImage ? URL.createObjectURL(file) : null;
    setPendingFile({ file, previewUrl });
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  const cancelPendingFile = () => {
    if (pendingFile?.previewUrl) URL.revokeObjectURL(pendingFile.previewUrl);
    setPendingFile(null);
  };

  const sendFile = async () => {
    if (!pendingFile) return;
    setIsUploading(true);
    try {
      const { file } = pendingFile;
      const ext = file.name.split(".").pop() || "bin";
      const filePath = `chat-files/${conversationId}/${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from("Metadesk")
        .upload(filePath, file, { contentType: file.type, upsert: false });

      if (uploadError) {
        console.error("Upload error:", uploadError);
        toast.error("Erro ao enviar arquivo.");
        return;
      }

      const { data: publicUrlData } = supabase.storage.from("Metadesk").getPublicUrl(filePath);
      const fileUrl = publicUrlData.publicUrl;
      const isImage = file.type.startsWith("image/");
      const content = isImage
        ? `[imagem:${file.name}](${fileUrl})`
        : `[arquivo:${file.name}](${fileUrl})`;

      let sessionId: string | null = null;
      const { data: existingSession } = await supabase
        .from("service_sessions").select("id")
        .eq("conversation_id", conversationId).eq("status", "active").maybeSingle();
      sessionId = existingSession?.id || null;

      if (!sessionId) {
        const { data: { user } } = await supabase.auth.getUser();
        if (!user) { toast.error("Você precisa estar autenticado."); return; }
        const { data: newSession, error: sessionError } = await supabase
          .from("service_sessions")
          .insert({ conversation_id: conversationId, attendant_id: user.id, complaint_id: queueItem?.complaint_id || null, status: "active" })
          .select().single();
        if (sessionError) { toast.error("Erro ao criar sessão."); return; }
        sessionId = newSession.id;
      }

      await supabase.from("service_messages").insert({
        session_id: sessionId, sender_type: "agent", content,
        metadata: { type: "file", fileName: file.name, fileUrl, mimeType: file.type },
      });

      await supabase.from("service_queue")
        .update({ last_message: `📎 ${file.name}`, status: "in_progress" })
        .eq("id", conversationId);

      setMessages(prev => [...prev, {
        id: crypto.randomUUID(), content, sender_type: "agent", created_at: new Date().toISOString(),
      }]);

      cancelPendingFile();
      toast.success("Arquivo enviado!");
    } catch (error) {
      console.error("Error sending file:", error);
      toast.error("Erro ao enviar arquivo.");
    } finally {
      setIsUploading(false);
    }
  };

  const handleForward = async (stepId: string, notes: string, summary?: string, complaintType?: string) => {
    if (onForward) {
      return await onForward(stepId, notes, summary, complaintType);
    }
    toast.success("Atendimento encaminhado com sucesso!");
    return true;
  };

  const handleEndSession = async () => {
    try {
      // 1. Find the active session for this conversation
      const { data: activeSession } = await supabase
        .from("service_sessions")
        .select("id, complaint_id")
        .eq("conversation_id", conversationId)
        .eq("status", "active")
        .maybeSingle();

      const sessionId = activeSession?.id;

      // 2. Get the protocol number from the linked complaint
      let protocolNumber = "";
      const complaintId = activeSession?.complaint_id || queueItem?.complaint_id;
      if (complaintId) {
        const { data: complaint } = await supabase
          .from("complaints")
          .select("protocol_number")
          .eq("id", complaintId)
          .maybeSingle();
        protocolNumber = complaint?.protocol_number || "";
      }

      // 3. Send automatic thank-you message
      if (sessionId) {
        const thankYouMessage = protocolNumber
          ? `✅ Atendimento finalizado.\n\nObrigado pelo seu contato! Caso precise retomar esta solicitação futuramente, utilize o número do protocolo: **${protocolNumber}**.\n\nAgradecemos a sua confiança. Até breve! 😊`
          : `✅ Atendimento finalizado.\n\nObrigado pelo seu contato! Agradecemos a sua confiança. Até breve! 😊`;

        await supabase.from("service_messages").insert({
          session_id: sessionId,
          sender_type: "bot",
          content: thankYouMessage,
        });

        // 4. Send NPS survey message
        const npsMessage = `📊 **Pesquisa de Satisfação**\n\nEm uma escala de 0 a 10, qual a probabilidade de você recomendar nosso atendimento?\n\nSua opinião é muito importante para melhorarmos continuamente. Obrigado!`;

        await supabase.from("service_messages").insert({
          session_id: sessionId,
          sender_type: "bot",
          content: npsMessage,
        });
      }

      // 5. Mark the queue item as completed
      await supabase
        .from("service_queue")
        .update({ status: "completed" })
        .eq("id", conversationId);

      // 6. Update complaint status to "resolvido" and log audit
      const { data: { user } } = await supabase.auth.getUser();
      if (complaintId) {
        await supabase
          .from("complaints")
          .update({ status: "resolvido", updated_at: new Date().toISOString() })
          .eq("id", complaintId);

        await supabase.from("complaint_audit_log").insert({
          complaint_id: complaintId,
          action: "resolved",
          field_changed: "status",
          old_value: "em_analise",
          new_value: "resolvido",
          notes: "Atendimento finalizado pelo atendente",
          user_id: user?.id || null,
        });
      }

      // 6. Call the parent handler to end the session
      if (onEndSession) {
        onEndSession();
      }
    } catch (error) {
      console.error("Error finalizing session:", error);
      toast.error("Erro ao finalizar atendimento.");
    }
  };

  const getSenderIcon = (senderType: string) => {
    switch (senderType) {
      case "bot":
        return <Bot className="h-4 w-4" />;
      case "agent":
        return <Headset className="h-4 w-4" />;
      default:
        return <User className="h-4 w-4" />;
    }
  };

  const getSenderLabel = (senderType: string) => {
    switch (senderType) {
      case "bot": return "Max (Bot)";
      case "agent": return "Atendente";
      default: return queueItem?.customer_name || "Cliente";
    }
  };

  // Render message content - handles file attachments
  const renderContent = (content: string) => {
    const imageMatch = content.match(/^\[imagem:(.+?)\]\((.+?)\)$/);
    if (imageMatch) {
      const [, fileName, url] = imageMatch;
      return (
        <div className="space-y-1">
          <img src={url} alt={fileName} className="max-w-[240px] rounded-md cursor-pointer" onClick={() => window.open(url, "_blank")} />
          <p className="text-[10px] opacity-70 flex items-center gap-1">
            <ImageIcon className="h-3 w-3" /> {fileName}
          </p>
        </div>
      );
    }
    const fileMatch = content.match(/^\[arquivo:(.+?)\]\((.+?)\)$/);
    if (fileMatch) {
      const [, fileName, url] = fileMatch;
      return (
        <a href={url} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 p-2 rounded-md bg-background/50 hover:bg-background/80 transition-colors">
          <FileIcon className="h-5 w-5 flex-shrink-0" />
          <span className="text-sm truncate flex-1">{fileName}</span>
          <Download className="h-4 w-4 flex-shrink-0 opacity-60" />
        </a>
      );
    }
    return <p className="text-sm whitespace-pre-wrap">{content}</p>;
  };

  const customerName = queueItem?.customer_name || "Cliente";
  const customerInitial = customerName.charAt(0).toUpperCase();

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="border-b p-4">
        <div className="flex justify-between items-center">
          <div className="flex items-center gap-3">
            {queueItem?.customer_avatar ? (
              <img
                src={queueItem.customer_avatar}
                alt={customerName}
                className="w-10 h-10 rounded-full object-cover"
              />
            ) : (
              <div className="w-10 h-10 rounded-full bg-muted flex items-center justify-center">
                <span className="text-sm font-medium text-muted-foreground">
                  {customerInitial}
                </span>
              </div>
            )}
            <div>
              <div className="flex items-center gap-2">
                <h3 className="font-medium">{customerName}</h3>
                {queueItem?.channel === 'whatsapp' && (
                  <Badge className="gap-1 bg-green-500/10 text-green-600 border-green-500/20 hover:bg-green-500/10">
                    <svg className="h-3 w-3 fill-current" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                      <path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413z"/>
                    </svg>
                    WhatsApp
                  </Badge>
                )}
              </div>
              <p className="text-xs text-muted-foreground">
                {queueItem?.subject || "Atendimento"}
                {queueItem?.customer_phone && queueItem?.channel === 'whatsapp' && ` • ${queueItem.customer_phone}`}
              </p>
            </div>
          </div>
          <div className="flex gap-1">
          </div>
        </div>
      </div>

      {/* Toolbar */}
      <ConversationToolbar
        activeMode={activeMode}
        onModeChange={setActiveMode}
        onForwardClick={() => setShowForwardModal(true)}
        onEndSession={handleEndSession}
        hasActiveSession={hasActiveSession}
      />

      {/* Main content */}
      <div className="flex-grow flex overflow-hidden">
        <div className="flex-grow flex flex-col">
          {activeMode === "chat" && (
            <>
              <div className="bg-muted/20 p-4 border-b">
                <Tabs defaultValue="atendimento">
                  <TabsList>
                    <TabsTrigger value="atendimento">Atendimento</TabsTrigger>
                    <TabsTrigger value="solicitacoes">Solicitações</TabsTrigger>
                    <TabsTrigger value="historico">Histórico</TabsTrigger>
                  </TabsList>
                </Tabs>
              </div>

              <div ref={scrollRef} className="flex-grow overflow-y-auto p-4">
                {isLoadingMessages ? (
                  <div className="flex items-center justify-center h-32">
                    <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                  </div>
                ) : timeline.length === 0 ? (
                  <div className="flex flex-col items-center justify-center h-32 text-muted-foreground">
                    <p className="text-sm">Nenhuma mensagem ainda. Envie uma mensagem para iniciar o atendimento.</p>
                  </div>
                ) : (
                  <div className="space-y-4">
                    {timeline.map((entry) =>
                      entry.sender_type === "system" ? (
                        <div key={entry.id} className="flex justify-center my-2">
                          <div className="bg-muted/60 border border-border/50 rounded-lg px-4 py-2 max-w-[85%] text-center">
                            <div className="flex items-center justify-center gap-2 mb-0.5">
                              <Info className="h-3.5 w-3.5 text-muted-foreground" />
                              <span className="text-[10px] text-muted-foreground">
                                {new Date(entry.created_at).toLocaleString("pt-BR", {
                                  day: "2-digit",
                                  month: "2-digit",
                                  hour: "2-digit",
                                  minute: "2-digit",
                                })}
                              </span>
                            </div>
                            <p className="text-xs text-muted-foreground whitespace-pre-wrap">{entry.content}</p>
                          </div>
                        </div>
                      ) : (
                        <div
                          key={entry.id}
                          className={cn(
                            "flex",
                            entry.sender_type === "agent" ? "justify-end" : "justify-start"
                          )}
                        >
                          <div
                            className={cn(
                              "max-w-[75%] rounded-lg p-3",
                              entry.sender_type === "agent"
                                ? "bg-primary text-primary-foreground"
                                : entry.sender_type === "bot"
                                ? "bg-accent"
                                : "bg-muted"
                            )}
                          >
                            <div className="flex items-center gap-2 mb-1">
                              {getSenderIcon(entry.sender_type)}
                              <span className="text-xs font-medium">
                                {getSenderLabel(entry.sender_type)}
                              </span>
                              <span className="text-xs opacity-70">
                                {new Date(entry.created_at).toLocaleTimeString("pt-BR", {
                                  hour: "2-digit",
                                  minute: "2-digit",
                                })}
                              </span>
                            </div>
                            {renderContent(entry.content)}
                          </div>
                        </div>
                      )
                    )}
                  </div>
                )}
              </div>

              <div className="border-t p-4">
                {/* Pending file preview */}
                {pendingFile && (
                  <div className="mb-3 p-3 border rounded-lg bg-muted/30 flex items-center gap-3">
                    {pendingFile.previewUrl ? (
                      <img src={pendingFile.previewUrl} alt="Preview" className="h-16 w-16 object-cover rounded-md" />
                    ) : (
                      <div className="h-16 w-16 rounded-md bg-muted flex items-center justify-center">
                        <FileIcon className="h-6 w-6 text-muted-foreground" />
                      </div>
                    )}
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium truncate">{pendingFile.file.name}</p>
                      <p className="text-xs text-muted-foreground">
                        {(pendingFile.file.size / 1024).toFixed(1)} KB
                      </p>
                    </div>
                    <Button variant="ghost" size="icon" onClick={cancelPendingFile} className="flex-shrink-0">
                      <X className="h-4 w-4" />
                    </Button>
                    <Button onClick={sendFile} disabled={isUploading} size="sm" className="flex-shrink-0">
                      {isUploading ? <Loader2 className="h-4 w-4 animate-spin mr-1" /> : <Send className="h-4 w-4 mr-1" />}
                      Enviar
                    </Button>
                  </div>
                )}

                {/* Hidden file input */}
                <input
                  ref={fileInputRef}
                  type="file"
                  className="hidden"
                  onChange={handleFileSelect}
                  accept="image/*,.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.txt,.csv,.zip,.rar"
                />

                <div className="flex gap-2">
                  <Textarea
                    placeholder="Digite sua mensagem..."
                    className="min-h-[60px]"
                    value={newMessage}
                    onChange={(e) => setNewMessage(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && !e.shiftKey) {
                        e.preventDefault();
                        handleSend();
                      }
                    }}
                    disabled={isSending}
                  />
                  <div className="flex flex-col gap-2">
                    <TooltipProvider>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button variant="outline" size="icon" onClick={() => fileInputRef.current?.click()}>
                            <Paperclip className="h-4 w-4" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Anexar arquivo</TooltipContent>
                      </Tooltip>
                      
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button variant="outline" size="icon">
                            <Smile className="h-4 w-4" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Emoji</TooltipContent>
                      </Tooltip>
                      
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button onClick={handleSend} disabled={isSending || !newMessage.trim()}>
                            {isSending ? (
                              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                            ) : (
                              <Send className="h-4 w-4 mr-2" />
                            )}
                            Enviar
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Enviar mensagem</TooltipContent>
                      </Tooltip>
                    </TooltipProvider>
                  </div>
                </div>
              </div>
            </>
          )}

          {activeMode === "documents" && (
            <div className="flex-grow flex items-center justify-center text-muted-foreground">
              <div className="text-center">
                <PanelRight className="h-12 w-12 mx-auto mb-4 opacity-50" />
                <h3 className="text-lg font-medium mb-2">Documentos do Caso</h3>
                <p className="text-sm">Nenhum documento anexado ainda.</p>
              </div>
            </div>
          )}
        </div>

        {activeMode === "quick-messages" && (
          <div className="w-80 border-l">
            <QuickMessagesPanel
              onSelect={handleInsertQuickMessage}
              onClose={() => setActiveMode("chat")}
            />
          </div>
        )}
      </div>

      <ForwardModal
        open={showForwardModal}
        onOpenChange={setShowForwardModal}
        onForward={handleForward}
        currentComplaintType={queueItem?.channel === "web" ? "reclamacao" : undefined}
      />
    </div>
  );
}
