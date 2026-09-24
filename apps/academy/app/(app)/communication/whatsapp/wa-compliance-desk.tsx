'use client';

import * as React from 'react';
import {
  MessageSquare,
  Clock,
  CheckCircle2,
  AlertTriangle,
  XCircle,
  RefreshCw,
  Send,
  ShieldAlert,
  Plus,
  PhoneIncoming,
  Search,
  Check,
  ChevronRight,
  Info,
} from 'lucide-react';
import { useRouter } from 'next/navigation';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Modal } from '@/components/ui/modal';
import {
  type WhatsAppComplianceData,
  type WaTemplateRow,
  type WaTemplateStatus,
  type WaTemplateCategory,
  getWhatsAppComplianceData,
  simulateInboundMessage,
  registerMetaTemplate,
  syncMetaTemplateStatus,
  testWhatsAppDispatch,
  resolveComplianceAlert,
} from './actions';

export function WhatsAppComplianceDesk({ initialData }: { initialData: WhatsAppComplianceData }) {
  const router = useRouter();
  const [data, setData] = React.useState<WhatsAppComplianceData>(initialData);
  const [activeTab, setActiveTab] = React.useState<'windows' | 'templates' | 'alerts' | 'simulator'>('windows');
  const [searchMsisdn, setSearchMsisdn] = React.useState('');
  const [templateStatusFilter, setTemplateStatusFilter] = React.useState<string>('all');

  // Modals state
  const [inboundModalOpen, setInboundModalOpen] = React.useState(false);
  const [inboundPhone, setInboundPhone] = React.useState('+923001234567');
  const [inboundBody, setInboundBody] = React.useState('Hello, I am asking about my son attendance.');
  const [inboundLoading, setInboundLoading] = React.useState(false);

  const [registerModalOpen, setRegisterModalOpen] = React.useState(false);
  const [templateName, setTemplateName] = React.useState('');
  const [templateCategory, setTemplateCategory] = React.useState<WaTemplateCategory>('UTILITY');
  const [templateBody, setTemplateBody] = React.useState('');
  const [registerLoading, setRegisterLoading] = React.useState(false);

  // Status Sync Modal state
  const [syncModalOpen, setSyncModalOpen] = React.useState(false);
  const [selectedTemplate, setSelectedTemplate] = React.useState<WaTemplateRow | null>(null);
  const [newStatus, setNewStatus] = React.useState<WaTemplateStatus>('APPROVED');
  const [rejectionReason, setRejectionReason] = React.useState('');
  const [syncLoading, setSyncLoading] = React.useState(false);

  // Dispatch Simulator state
  const [simPhone, setSimPhone] = React.useState('+923009876543');
  const [simIsFreeform, setSimIsFreeform] = React.useState(true);
  const [simTemplateId, setSimTemplateId] = React.useState<string>('');
  const [simBody, setSimBody] = React.useState('Your student has arrived safely at campus.');
  const [simLoading, setSimLoading] = React.useState(false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [simResult, setSimResult] = React.useState<any>(null);

  const [flashMessage, setFlashMessage] = React.useState<{ type: 'success' | 'error'; text: string } | null>(null);

  React.useEffect(() => {
    setData(initialData);
    if (!simTemplateId && initialData.templates.length > 0 && initialData.templates[0]) {
      setSimTemplateId(initialData.templates[0].id);
    }
  }, [initialData, simTemplateId]);

  const showFlash = (type: 'success' | 'error', text: string) => {
    setFlashMessage({ type, text });
    setTimeout(() => setFlashMessage(null), 5000);
  };

  const refreshData = async () => {
    try {
      const fresh = await getWhatsAppComplianceData();
      setData(fresh);
      router.refresh();
    } catch (err) {
      console.error('Failed to refresh WhatsApp data:', err);
    }
  };

  // Handlers
  const handleSimulateInbound = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!inboundPhone.trim()) return;
    setInboundLoading(true);
    const res = await simulateInboundMessage({ phone: inboundPhone, body: inboundBody });
    setInboundLoading(false);
    if (res.success) {
      showFlash('success', `Inbound message processed! 24h window opened/renewed for ${inboundPhone}`);
      setInboundModalOpen(false);
      await refreshData();
    } else {
      showFlash('error', res.error || 'Failed to process inbound message');
    }
  };

  const handleRegisterTemplate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!templateName.trim() || !templateBody.trim()) return;
    setRegisterLoading(true);
    const res = await registerMetaTemplate({
      name: templateName,
      category: templateCategory,
      bodyText: templateBody,
    });
    setRegisterLoading(false);
    if (res.success) {
      showFlash('success', `Template "${templateName}" submitted for Meta review (status: PENDING)`);
      setRegisterModalOpen(false);
      setTemplateName('');
      setTemplateBody('');
      await refreshData();
    } else {
      showFlash('error', res.error || 'Failed to register template');
    }
  };

  const handleSyncStatus = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedTemplate) return;
    setSyncLoading(true);
    const res = await syncMetaTemplateStatus({
      templateId: selectedTemplate.id,
      newStatus,
      rejectionReason: newStatus === 'REJECTED' ? rejectionReason : undefined,
    });
    setSyncLoading(false);
    if (res.success) {
      showFlash('success', `Meta status updated for "${selectedTemplate.meta_template_name}" -> ${newStatus}`);
      setSyncModalOpen(false);
      await refreshData();
    } else {
      showFlash('error', res.error || 'Failed to update template status');
    }
  };

  const handleRunSimulator = async () => {
    if (!simPhone.trim()) return;
    setSimLoading(true);
    setSimResult(null);
    const res = await testWhatsAppDispatch({
      phone: simPhone,
      isFreeform: simIsFreeform,
      templateId: simTemplateId,
      body: simBody,
    });
    setSimLoading(false);
    setSimResult(res);
  };

  const handleResolveAlert = async (alertId: string) => {
    const res = await resolveComplianceAlert(alertId);
    if (res.success) {
      showFlash('success', 'Compliance alert marked as resolved');
      await refreshData();
    } else {
      showFlash('error', res.error || 'Failed to resolve alert');
    }
  };

  // Filtered lists
  const filteredWindows = data.sessionWindows.filter((w) =>
    searchMsisdn ? w.msisdn.toLowerCase().includes(searchMsisdn.toLowerCase()) : true
  );

  const filteredTemplates = data.templates.filter((t) => {
    if (templateStatusFilter === 'all') return true;
    return t.status === templateStatusFilter;
  });

  const activeWindowsCount = data.stats.activeSessionWindows;

  return (
    <div className="space-y-6">
      {/* Top Notification Flash */}
      {flashMessage && (
        <div
          className={`flex items-center gap-2 p-4 rounded-lg text-sm font-medium ${
            flashMessage.type === 'success'
              ? 'bg-emerald-50 text-emerald-900 border border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:border-emerald-800'
              : 'bg-rose-50 text-rose-900 border border-rose-200 dark:bg-rose-950/40 dark:text-rose-300 dark:border-rose-800'
          }`}
        >
          {flashMessage.type === 'success' ? (
            <CheckCircle2 className="h-5 w-5 text-emerald-600 dark:text-emerald-400 shrink-0" />
          ) : (
            <AlertTriangle className="h-5 w-5 text-rose-600 dark:text-rose-400 shrink-0" />
          )}
          <span>{flashMessage.text}</span>
        </div>
      )}

      {/* Header and Quick Action Buttons */}
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between border-b pb-5">
        <div>
          <div className="flex items-center gap-2">
            <span className="p-2 rounded-lg bg-emerald-100 text-emerald-700 dark:bg-emerald-900/50 dark:text-emerald-300">
              <MessageSquare className="h-6 w-6" />
            </span>
            <h1 className="text-2xl font-bold tracking-tight">WhatsApp Compliance Desk</h1>
            <Badge variant="outline" className="border-emerald-500 text-emerald-600 dark:text-emerald-400">
              Meta 24h Enforced
            </Badge>
          </div>
          <p className="text-sm text-muted-foreground mt-1">
            Meta 24-hour customer service session window gating, approved template whitelist, and automated SMS fallback (FR-M05).
          </p>
        </div>

        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => setInboundModalOpen(true)}
            className="flex items-center gap-1.5"
          >
            <PhoneIncoming className="h-4 w-4 text-emerald-600" />
            Simulate Inbound Message
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setRegisterModalOpen(true)}
            className="flex items-center gap-1.5"
          >
            <Plus className="h-4 w-4" />
            Register Meta Template
          </Button>
          <Button
            size="sm"
            onClick={() => setActiveTab('simulator')}
            className="flex items-center gap-1.5 bg-emerald-600 hover:bg-emerald-700 text-white"
          >
            <Send className="h-4 w-4" />
            Dispatch & Fallback Tester
          </Button>
        </div>
      </div>

      {/* KPI Metric Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Card className="border-border">
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs uppercase font-semibold">Active 24h Windows</CardDescription>
            <CardTitle className="text-2xl font-bold flex items-center justify-between">
              <span className="text-emerald-600 dark:text-emerald-400">{activeWindowsCount}</span>
              <Clock className="h-5 w-5 text-emerald-500" />
            </CardTitle>
          </CardHeader>
          <CardContent className="p-4 pt-0">
            <p className="text-xs text-muted-foreground">
              {data.stats.totalSessionWindows} total parent contacts recorded
            </p>
          </CardContent>
        </Card>

        <Card className="border-border">
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs uppercase font-semibold">Approved Templates</CardDescription>
            <CardTitle className="text-2xl font-bold flex items-center justify-between">
              <span className="text-blue-600 dark:text-blue-400">{data.stats.approvedTemplates}</span>
              <CheckCircle2 className="h-5 w-5 text-blue-500" />
            </CardTitle>
          </CardHeader>
          <CardContent className="p-4 pt-0">
            <p className="text-xs text-muted-foreground">
              Whitelisted for outbound dispatch outside 24h
            </p>
          </CardContent>
        </Card>

        <Card className="border-border">
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs uppercase font-semibold">Pending / Under Review</CardDescription>
            <CardTitle className="text-2xl font-bold flex items-center justify-between">
              <span className="text-amber-600 dark:text-amber-400">{data.stats.pendingTemplates}</span>
              <RefreshCw className="h-5 w-5 text-amber-500" />
            </CardTitle>
          </CardHeader>
          <CardContent className="p-4 pt-0">
            <p className="text-xs text-muted-foreground">
              Blocked from outbound campaigns until approved
            </p>
          </CardContent>
        </Card>

        <Card className="border-border">
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs uppercase font-semibold">Principal Alerts</CardDescription>
            <CardTitle className="text-2xl font-bold flex items-center justify-between">
              <span className={data.stats.unresolvedAlerts > 0 ? 'text-rose-600 dark:text-rose-400' : 'text-slate-600'}>
                {data.stats.unresolvedAlerts}
              </span>
              <ShieldAlert className="h-5 w-5 text-rose-500" />
            </CardTitle>
          </CardHeader>
          <CardContent className="p-4 pt-0">
            <p className="text-xs text-muted-foreground">
              {data.stats.rejectedTemplates} rejected / paused Meta templates
            </p>
          </CardContent>
        </Card>
      </div>

      {/* Tabs Navigation */}
      <div className="flex border-b space-x-4">
        <button
          onClick={() => setActiveTab('windows')}
          className={`pb-3 text-sm font-medium border-b-2 transition-colors flex items-center gap-2 ${
            activeTab === 'windows'
              ? 'border-emerald-600 text-emerald-600 dark:border-emerald-400 dark:text-emerald-400'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Clock className="h-4 w-4" />
          Active 24h Session Windows ({data.sessionWindows.length})
        </button>
        <button
          onClick={() => setActiveTab('templates')}
          className={`pb-3 text-sm font-medium border-b-2 transition-colors flex items-center gap-2 ${
            activeTab === 'templates'
              ? 'border-emerald-600 text-emerald-600 dark:border-emerald-400 dark:text-emerald-400'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <CheckCircle2 className="h-4 w-4" />
          Meta Template Whitelist ({data.templates.length})
        </button>
        <button
          onClick={() => setActiveTab('alerts')}
          className={`pb-3 text-sm font-medium border-b-2 transition-colors flex items-center gap-2 ${
            activeTab === 'alerts'
              ? 'border-emerald-600 text-emerald-600 dark:border-emerald-400 dark:text-emerald-400'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <ShieldAlert className="h-4 w-4" />
          Compliance Alerts ({data.complianceAlerts.length})
          {data.stats.unresolvedAlerts > 0 && (
            <span className="h-2 w-2 rounded-full bg-rose-500" />
          )}
        </button>
        <button
          onClick={() => setActiveTab('simulator')}
          className={`pb-3 text-sm font-medium border-b-2 transition-colors flex items-center gap-2 ${
            activeTab === 'simulator'
              ? 'border-emerald-600 text-emerald-600 dark:border-emerald-400 dark:text-emerald-400'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Send className="h-4 w-4" />
          Dispatch & Fallback Simulator
        </button>
      </div>

      {/* TAB 1: 24-HOUR SESSION WINDOWS */}
      {activeTab === 'windows' && (
        <div className="space-y-4">
          <div className="flex flex-col sm:flex-row gap-3 justify-between items-center">
            <div className="relative w-full sm:w-72">
              <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
              <Input
                placeholder="Search phone (MSISDN)..."
                value={searchMsisdn}
                onChange={(e) => setSearchMsisdn(e.target.value)}
                className="pl-8 text-sm"
              />
            </div>
            <div className="text-xs text-muted-foreground">
              A 24-hour customer service window opens only when a parent initiates a message. Free-form responses are allowed only while this window remains active.
            </div>
          </div>

          <div className="rounded-lg border bg-card overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-muted/40 text-left font-medium text-muted-foreground">
                    <th className="p-3">Parent MSISDN</th>
                    <th className="p-3">Session Window Status</th>
                    <th className="p-3">Window Opened At</th>
                    <th className="p-3">Window Expires At</th>
                    <th className="p-3">Time Remaining</th>
                    <th className="p-3 text-right">Quick Action</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {filteredWindows.length === 0 ? (
                    <tr>
                      <td colSpan={6} className="p-8 text-center text-muted-foreground">
                        <div className="flex flex-col items-center justify-center gap-2">
                          <Clock className="h-8 w-8 text-muted-foreground/50" />
                          <p>No WhatsApp session windows found.</p>
                          <p className="text-xs">Simulate an incoming message to open the 24h customer service window.</p>
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => setInboundModalOpen(true)}
                            className="mt-2"
                          >
                            Simulate Inbound Message
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ) : (
                    filteredWindows.map((win) => {
                      const now = new Date();
                      const expiry = new Date(win.window_expires_at);
                      const diffMs = expiry.getTime() - now.getTime();
                      const isActive = diffMs > 0;
                      const hoursLeft = Math.floor(diffMs / (1000 * 60 * 60));
                      const minutesLeft = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60));

                      return (
                        <tr key={win.id} className="hover:bg-muted/30">
                          <td className="p-3 font-mono font-medium">{win.msisdn}</td>
                          <td className="p-3">
                            {isActive ? (
                              <Badge variant="success" dot className="font-medium">
                                Active 24h Window
                              </Badge>
                            ) : (
                              <Badge variant="destructive" className="font-medium">
                                Window Closed
                              </Badge>
                            )}
                          </td>
                          <td className="p-3 text-xs text-muted-foreground">
                            {new Date(win.window_opened_at).toLocaleString()}
                          </td>
                          <td className="p-3 text-xs text-muted-foreground">
                            {expiry.toLocaleString()}
                          </td>
                          <td className="p-3">
                            {isActive ? (
                              <span className="font-medium text-emerald-600 dark:text-emerald-400 text-xs">
                                {hoursLeft}h {minutesLeft}m remaining
                              </span>
                            ) : (
                              <span className="text-xs text-rose-600 dark:text-rose-400 font-medium">
                                Expired (SMS Fallback required)
                              </span>
                            )}
                          </td>
                          <td className="p-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              className="text-xs h-7"
                              onClick={() => {
                                setInboundPhone(win.msisdn);
                                setInboundModalOpen(true);
                              }}
                            >
                              Renew Window
                            </Button>
                          </td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          </div>

          {/* Inbound Message Audit Drawer */}
          {data.recentInbound.length > 0 && (
            <Card className="mt-6 border-dashed">
              <CardHeader className="p-4 pb-2">
                <CardTitle className="text-base font-semibold flex items-center gap-2">
                  <PhoneIncoming className="h-4 w-4 text-emerald-600" />
                  Recent Inbound Webhook Payloads
                </CardTitle>
                <CardDescription className="text-xs">
                  Webhook events received from Meta WhatsApp Cloud API that opened or refreshed customer service windows.
                </CardDescription>
              </CardHeader>
              <CardContent className="p-4 pt-0">
                <div className="space-y-2 mt-2">
                  {data.recentInbound.slice(0, 5).map((inb) => (
                    <div
                      key={inb.id}
                      className="flex items-center justify-between p-2.5 rounded bg-muted/40 text-xs"
                    >
                      <div className="space-y-0.5">
                        <div className="flex items-center gap-2">
                          <span className="font-mono font-semibold">{inb.msisdn}</span>
                          <span className="text-muted-foreground">({inb.wam_id || 'wam_webhook'})</span>
                        </div>
                        <p className="text-slate-700 dark:text-slate-300 italic">&ldquo;{inb.body}&rdquo;</p>
                      </div>
                      <span className="text-muted-foreground whitespace-nowrap ml-4">
                        {new Date(inb.received_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </span>
                    </div>
                  ))}
                </div>
              </CardContent>
            </Card>
          )}
        </div>
      )}

      {/* TAB 2: META TEMPLATES WHITELIST */}
      {activeTab === 'templates' && (
        <div className="space-y-4">
          <div className="flex flex-col sm:flex-row gap-3 justify-between items-center">
            <div className="flex items-center gap-2">
              <span className="text-xs font-medium text-muted-foreground">Filter by Status:</span>
              <select
                className="text-xs rounded border bg-background px-2.5 py-1.5"
                value={templateStatusFilter}
                onChange={(e) => setTemplateStatusFilter(e.target.value)}
              >
                <option value="all">All Statuses ({data.templates.length})</option>
                <option value="APPROVED">Approved ({data.stats.approvedTemplates})</option>
                <option value="PENDING">Pending Review ({data.stats.pendingTemplates})</option>
                <option value="REJECTED">Rejected ({data.templates.filter((t) => t.status === 'REJECTED').length})</option>
                <option value="PAUSED">Paused ({data.templates.filter((t) => t.status === 'PAUSED').length})</option>
              </select>
            </div>

            <Button
              size="sm"
              onClick={() => setRegisterModalOpen(true)}
              className="flex items-center gap-1 text-xs"
            >
              <Plus className="h-3.5 w-3.5" />
              Register New Meta Template
            </Button>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {filteredTemplates.map((tmpl) => {
              const isApproved = tmpl.status === 'APPROVED';
              const isPending = tmpl.status === 'PENDING';
              const isRejected = tmpl.status === 'REJECTED' || tmpl.status === 'PAUSED';

              return (
                <Card key={tmpl.id} className="border-border flex flex-col justify-between">
                  <CardHeader className="p-4 pb-2">
                    <div className="flex items-start justify-between gap-2">
                      <div>
                        <div className="flex items-center gap-2">
                          <CardTitle className="text-base font-semibold font-mono">
                            {tmpl.meta_template_name}
                          </CardTitle>
                          <Badge variant="outline" className="text-[10px] uppercase font-mono">
                            {tmpl.category}
                          </Badge>
                        </div>
                        <p className="text-xs text-muted-foreground mt-0.5">Language: {tmpl.language}</p>
                      </div>

                      <Badge
                        variant={
                          isApproved ? 'success' : isPending ? 'warning' : 'destructive'
                        }
                        dot={isApproved}
                        className="text-xs"
                      >
                        {tmpl.status}
                      </Badge>
                    </div>
                  </CardHeader>

                  <CardContent className="p-4 pt-2 flex-1">
                    <div className="p-3 rounded-md bg-muted/60 text-xs font-mono text-slate-800 dark:text-slate-200 border border-muted">
                      {tmpl.body_text}
                    </div>

                    {tmpl.rejection_reason && (
                      <div className="mt-3 p-2.5 rounded bg-rose-50 border border-rose-200 dark:bg-rose-950/40 dark:border-rose-900 text-xs text-rose-800 dark:text-rose-300 space-y-1">
                        <div className="font-semibold flex items-center gap-1.5">
                          <XCircle className="h-3.5 w-3.5 text-rose-600 dark:text-rose-400" />
                          Meta Rejection Diagnostic:
                        </div>
                        <p>{tmpl.rejection_reason}</p>
                      </div>
                    )}
                  </CardContent>

                  <div className="p-3 border-t bg-muted/20 flex items-center justify-between text-xs">
                    <span className="text-muted-foreground">
                      Last synced: {new Date(tmpl.last_synced_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                    </span>
                    <Button
                      variant="outline"
                      size="sm"
                      className="text-xs h-7 flex items-center gap-1"
                      onClick={() => {
                        setSelectedTemplate(tmpl);
                        setNewStatus(tmpl.status);
                        setRejectionReason(tmpl.rejection_reason || '');
                        setSyncModalOpen(true);
                      }}
                    >
                      <RefreshCw className="h-3 w-3" />
                      Simulate Meta Status Sync
                    </Button>
                  </div>
                </Card>
              );
            })}
          </div>
        </div>
      )}

      {/* TAB 3: COMPLIANCE ALERTS */}
      {activeTab === 'alerts' && (
        <div className="space-y-4">
          <div className="text-xs text-muted-foreground">
            Compliance alerts are automatically dispatched to the Principal when Meta invalidates or pauses an approved template. Active scheduled campaigns referencing the template are paused immediately to prevent business account quality degradation.
          </div>

          <div className="space-y-3">
            {data.complianceAlerts.length === 0 ? (
              <Card className="p-8 text-center text-muted-foreground border-dashed">
                <CheckCircle2 className="h-8 w-8 text-emerald-500 mx-auto mb-2" />
                <p className="font-medium text-foreground">Zero Compliance Violations</p>
                <p className="text-xs mt-1">All Meta WhatsApp templates are compliant with Meta Business Messaging Policy.</p>
              </Card>
            ) : (
              data.complianceAlerts.map((alert) => (
                <div
                  key={alert.id}
                  className={`p-4 rounded-lg border flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 ${
                    alert.is_resolved
                      ? 'bg-muted/30 border-border opacity-70'
                      : 'bg-rose-50/50 border-rose-200 dark:bg-rose-950/20 dark:border-rose-900'
                  }`}
                >
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <ShieldAlert
                        className={`h-4 w-4 ${alert.is_resolved ? 'text-muted-foreground' : 'text-rose-600'}`}
                      />
                      <h4 className="font-semibold text-sm">{alert.title}</h4>
                      {alert.is_resolved ? (
                        <Badge variant="outline" className="text-[10px]">Resolved</Badge>
                      ) : (
                        <Badge variant="destructive" className="text-[10px]">Action Required</Badge>
                      )}
                    </div>
                    <p className="text-xs text-muted-foreground max-w-2xl">{alert.message}</p>
                    <span className="text-[11px] text-muted-foreground">
                      Dispatched: {new Date(alert.created_at).toLocaleString()}
                    </span>
                  </div>

                  {!alert.is_resolved && (
                    <Button
                      size="sm"
                      variant="outline"
                      className="text-xs shrink-0"
                      onClick={() => handleResolveAlert(alert.id)}
                    >
                      <Check className="h-3.5 w-3.5 mr-1" />
                      Mark Resolved
                    </Button>
                  )}
                </div>
              ))
            )}
          </div>
        </div>
      )}

      {/* TAB 4: DISPATCH & FALLBACK SIMULATOR */}
      {activeTab === 'simulator' && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Simulator Controls */}
          <Card className="border-border">
            <CardHeader className="p-4 pb-3">
              <CardTitle className="text-base font-semibold flex items-center gap-2">
                <Send className="h-4 w-4 text-emerald-600" />
                WhatsApp Dispatch & 24h Window Tester
              </CardTitle>
              <CardDescription className="text-xs">
                Test how the Seena message outbox enforces 24-hour Meta session window rules and executes fallback to SMS.
              </CardDescription>
            </CardHeader>
            <CardContent className="p-4 pt-0 space-y-4">
              <div>
                <label htmlFor="sim-phone-input" className="text-xs font-medium">Recipient MSISDN (Phone)</label>
                <Input
                  id="sim-phone-input"
                  data-testid="sim-phone-input"
                  className="mt-1 font-mono text-sm"
                  value={simPhone}
                  onChange={(e) => setSimPhone(e.target.value)}
                  placeholder="+923001234567"
                />
                <p className="text-[11px] text-muted-foreground mt-1">
                  Tip: Use one of the phone numbers from the &ldquo;Active 24h Session Windows&rdquo; tab or a new unengaged number to test closed window rejection.
                </p>
              </div>

              <div>
                <label className="text-xs font-medium">Message Type</label>
                <div className="grid grid-cols-2 gap-2 mt-1">
                  <button
                    type="button"
                    onClick={() => setSimIsFreeform(true)}
                    className={`p-3 rounded-lg border text-left text-xs transition-colors ${
                      simIsFreeform
                        ? 'border-emerald-600 bg-emerald-50 dark:bg-emerald-950/30 text-emerald-900 dark:text-emerald-200 font-semibold'
                        : 'border-border bg-card hover:bg-muted'
                    }`}
                  >
                    <div className="flex items-center gap-1.5">
                      <MessageSquare className="h-3.5 w-3.5" />
                      Free-form Content
                    </div>
                    <p className="text-[10px] font-normal text-muted-foreground mt-1">
                      Subject to 24h customer service session window check.
                    </p>
                  </button>

                  <button
                    type="button"
                    onClick={() => {
                      setSimIsFreeform(false);
                      const approved = data.templates.find((t) => t.status === 'APPROVED');
                      if (approved) {
                        setSimTemplateId(approved.id);
                      }
                    }}
                    className={`p-3 rounded-lg border text-left text-xs transition-colors ${
                      !simIsFreeform
                        ? 'border-emerald-600 bg-emerald-50 dark:bg-emerald-950/30 text-emerald-900 dark:text-emerald-200 font-semibold'
                        : 'border-border bg-card hover:bg-muted'
                    }`}
                  >
                    <div className="flex items-center gap-1.5">
                      <CheckCircle2 className="h-3.5 w-3.5" />
                      Meta Approved Template
                    </div>
                    <p className="text-[10px] font-normal text-muted-foreground mt-1">
                      Permitted outside 24h without opening customer window.
                    </p>
                  </button>
                </div>
              </div>

              {!simIsFreeform && (
                <div>
                  <label htmlFor="sim-template-select" className="text-xs font-medium">Select Registered Meta Template</label>
                  <select
                    id="sim-template-select"
                    data-testid="sim-template-select"
                    className="w-full mt-1 text-xs rounded border bg-background px-3 py-2"
                    value={simTemplateId}
                    onChange={(e) => setSimTemplateId(e.target.value)}
                  >
                    {data.templates.map((t) => (
                      <option key={t.id} value={t.id}>
                        {t.meta_template_name} ({t.status}) - {t.category}
                      </option>
                    ))}
                  </select>
                </div>
              )}

              <div>
                <label className="text-xs font-medium">Message Body</label>
                <textarea
                  className="w-full mt-1 text-xs rounded-md border bg-background p-2.5 font-mono min-h-[80px]"
                  value={simBody}
                  onChange={(e) => setSimBody(e.target.value)}
                />
              </div>

              <Button
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white flex items-center justify-center gap-2"
                onClick={handleRunSimulator}
                disabled={simLoading}
              >
                {simLoading ? (
                  <>
                    <RefreshCw className="h-4 w-4 animate-spin" />
                    Validating WhatsApp Rules...
                  </>
                ) : (
                  <>
                    <Send className="h-4 w-4" />
                    Simulate Dispatch & Evaluate Rules
                  </>
                )}
              </Button>
            </CardContent>
          </Card>

          {/* Simulator Diagnostics Output */}
          <Card className="border-border">
            <CardHeader className="p-4 pb-3">
              <CardTitle className="text-base font-semibold flex items-center gap-2">
                <Info className="h-4 w-4 text-blue-600" />
                Dispatch & Fallback Telemetry
              </CardTitle>
              <CardDescription className="text-xs">
                Real-time evaluation log showing Meta window status and FR-M02 channel fallback progression.
              </CardDescription>
            </CardHeader>
            <CardContent className="p-4 pt-0">
              {!simResult ? (
                <div className="h-64 flex flex-col items-center justify-center text-center text-muted-foreground p-6 border border-dashed rounded-lg">
                  <Send className="h-8 w-8 text-muted-foreground/40 mb-2" />
                  <p className="text-sm font-medium">No simulation run yet</p>
                  <p className="text-xs mt-1 max-w-xs">
                    Choose a phone number and message mode on the left, then click &ldquo;Simulate Dispatch&rdquo; to test 24h compliance.
                  </p>
                </div>
              ) : (
                <div className="space-y-4">
                  {/* Status Banner */}
                  <div
                    className={`p-3.5 rounded-lg border flex items-center gap-2.5 ${
                      simResult.validationResult?.valid
                        ? 'bg-emerald-50 border-emerald-200 text-emerald-900 dark:bg-emerald-950/40 dark:border-emerald-800 dark:text-emerald-300'
                        : 'bg-rose-50 border-rose-200 text-rose-900 dark:bg-rose-950/40 dark:border-rose-800 dark:text-rose-300'
                    }`}
                  >
                    {simResult.validationResult?.valid ? (
                      <CheckCircle2 className="h-5 w-5 text-emerald-600 shrink-0" />
                    ) : (
                      <XCircle className="h-5 w-5 text-rose-600 shrink-0" />
                    )}
                    <div>
                      <h4 className="font-semibold text-sm">
                        {simResult.validationResult?.valid
                          ? 'Dispatch Validation Passed'
                          : `Dispatch Blocked: ${simResult.validationResult?.error || 'Validation Failed'}`}
                      </h4>
                      <p className="text-xs mt-0.5 opacity-90">
                        {simResult.validationResult?.valid
                          ? simResult.validationResult?.mode === 'template_approved'
                            ? `Approved Meta template "${simResult.validationResult?.template}" permitted without artificial session window.`
                            : '24-hour customer service window is open. Free-form dispatch authorized.'
                          : simResult.validationResult?.error === 'WA_WINDOW_CLOSED'
                          ? 'Meta customer service 24-hour session window is closed. Outbound message automatically escalated to SMS.'
                          : `Template status prevents dispatch: ${simResult.validationResult?.error}`}
                      </p>
                    </div>
                  </div>

                  {/* Attempts & Fallback Chain */}
                  {simResult.attempts && simResult.attempts.length > 0 && (
                    <div className="space-y-2">
                      <h5 className="text-xs font-semibold text-muted-foreground uppercase">
                        Message Execution Chain ({simResult.attempts.length} Attempt{simResult.attempts.length > 1 ? 's' : ''})
                      </h5>
                      <div className="space-y-2">
                        {/* eslint-disable-next-line @typescript-eslint/no-explicit-any */}
                        {simResult.attempts.map((att: any, idx: number) => (
                          <div
                            key={att.id || idx}
                            className="p-3 rounded-lg border bg-muted/30 flex items-center justify-between text-xs font-mono"
                          >
                            <div className="flex items-center gap-2">
                              <span className="h-5 w-5 rounded-full bg-slate-200 dark:bg-slate-700 flex items-center justify-center font-bold text-[10px]">
                                {att.attempt_number}
                              </span>
                              <span className="font-semibold uppercase">{att.channel}</span>
                              <Badge
                                variant={att.status === 'failed' ? 'destructive' : 'info'}
                                className="text-[10px]"
                              >
                                {att.status}
                              </Badge>
                            </div>

                            <div className="text-right">
                              {att.error_code && (
                                <span className="font-semibold text-rose-600 dark:text-rose-400">
                                  [{att.error_code}]
                                </span>
                              )}
                              {att.channel === 'sms' && (
                                <span className="text-emerald-600 dark:text-emerald-400 font-semibold ml-2">
                                  Fallback Delivered
                                </span>
                              )}
                            </div>
                          </div>
                        ))}
                      </div>
                    </div>
                  )}

                  {/* Raw Telemetry JSON */}
                  <div className="mt-2">
                    <span className="text-[11px] font-semibold text-muted-foreground">Raw Response Data:</span>
                    <pre className="p-3 rounded bg-muted/60 text-[11px] font-mono overflow-x-auto mt-1 border">
                      {JSON.stringify(simResult.validationResult, null, 2)}
                    </pre>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        </div>
      )}

      {/* MODAL 1: SIMULATE INBOUND MESSAGE */}
      <Modal
        open={inboundModalOpen}
        onClose={() => setInboundModalOpen(false)}
        title="Simulate WhatsApp Inbound Message"
        description="Simulate receiving an inbound message from a parent. This opens/renews the 24-hour Meta customer service window."
      >
        <form onSubmit={handleSimulateInbound} className="space-y-4">
          <div>
            <label className="text-xs font-medium">Parent MSISDN (Phone)</label>
            <Input
              className="mt-1 font-mono text-sm"
              value={inboundPhone}
              onChange={(e) => setInboundPhone(e.target.value)}
              placeholder="+923001234567"
              required
            />
          </div>

          <div>
            <label className="text-xs font-medium">Parent Inbound Text</label>
            <textarea
              className="w-full mt-1 text-xs rounded-md border bg-background p-2.5 min-h-[80px]"
              value={inboundBody}
              onChange={(e) => setInboundBody(e.target.value)}
              placeholder="Type simulated message..."
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setInboundModalOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              size="sm"
              className="bg-emerald-600 hover:bg-emerald-700 text-white"
              disabled={inboundLoading}
            >
              {inboundLoading ? 'Processing...' : 'Simulate & Open 24h Window'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* MODAL 2: REGISTER META TEMPLATE */}
      <Modal
        open={registerModalOpen}
        onClose={() => setRegisterModalOpen(false)}
        title="Register New Meta Template"
        description="Submit a new template name and text for Meta review. Templates default to PENDING status."
      >
        <form onSubmit={handleRegisterTemplate} className="space-y-4">
          <div>
            <label className="text-xs font-medium">Template Name (e.g. fee_reminder_v2)</label>
            <Input
              className="mt-1 font-mono text-sm"
              value={templateName}
              onChange={(e) => setTemplateName(e.target.value)}
              placeholder="exam_dates_v1"
              required
            />
          </div>

          <div>
            <label className="text-xs font-medium">Meta Category</label>
            <select
              className="w-full mt-1 text-xs rounded border bg-background px-3 py-2"
              value={templateCategory}
              onChange={(e) => setTemplateCategory(e.target.value as WaTemplateCategory)}
            >
              <option value="UTILITY">UTILITY (Transactional, Fees, Attendance)</option>
              <option value="MARKETING">MARKETING (Events, Promotions)</option>
              <option value="AUTHENTICATION">AUTHENTICATION (OTPs)</option>
              <option value="SERVICE">SERVICE (Customer Support)</option>
            </select>
          </div>

          <div>
            <label className="text-xs font-medium">Body Text (Use {"{{1}}"}, {"{{2}}"} placeholders)</label>
            <textarea
              className="w-full mt-1 text-xs rounded-md border bg-background p-2.5 font-mono min-h-[90px]"
              value={templateBody}
              onChange={(e) => setTemplateBody(e.target.value)}
              placeholder="Dear Parent, exams for {{1}} begin on {{2}}."
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setRegisterModalOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              size="sm"
              className="bg-emerald-600 hover:bg-emerald-700 text-white"
              disabled={registerLoading}
            >
              {registerLoading ? 'Submitting...' : 'Register Meta Template'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* MODAL 3: SIMULATE META STATUS SYNC */}
      <Modal
        open={syncModalOpen}
        onClose={() => setSyncModalOpen(false)}
        title="Simulate Meta Status Sync"
        description={`Simulate a Meta webhook updating the status of "${selectedTemplate?.meta_template_name}".`}
      >
        <form onSubmit={handleSyncStatus} className="space-y-4">
          <div>
            <label htmlFor="meta-review-status" className="text-xs font-medium">Meta Review Status</label>
            <select
              id="meta-review-status"
              className="w-full mt-1 text-xs rounded border bg-background px-3 py-2"
              value={newStatus}
              onChange={(e) => setNewStatus(e.target.value as WaTemplateStatus)}
            >
              <option value="APPROVED">APPROVED (Whitelisted for Outbound)</option>
              <option value="PENDING">PENDING (Under Meta Review)</option>
              <option value="REJECTED">REJECTED (Triggers Auto-Pause & Principal Alert)</option>
              <option value="PAUSED">PAUSED (Triggers Auto-Pause & Principal Alert)</option>
            </select>
          </div>

          {newStatus === 'REJECTED' && (
            <div>
              <label className="text-xs font-medium">Rejection Reason</label>
              <Input
                className="mt-1 text-xs"
                value={rejectionReason}
                onChange={(e) => setRejectionReason(e.target.value)}
                placeholder="Violates Meta Commerce Policy section 4.3"
                required
              />
            </div>
          )}

          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setSyncModalOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              size="sm"
              className="bg-blue-600 hover:bg-blue-700 text-white"
              disabled={syncLoading}
            >
              {syncLoading ? 'Syncing...' : 'Update Meta Status'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
