"use client";

import { useEffect, useState, useCallback, createContext, useContext, type ReactNode } from "react";

export type ToastType = "pending" | "success" | "error";

interface Toast {
  id: number;
  type: ToastType;
  title: string;
  message?: string;
  txHash?: string;
  duration?: number;
}

interface ToastContextType {
  addToast: (toast: Omit<Toast, "id">) => void;
}

const ToastContext = createContext<ToastContextType>({ addToast: () => {} });
export const useToast = () => useContext(ToastContext);

let nextId = 0;

function ToastItem({ toast, onRemove }: { toast: Toast; onRemove: () => void }) {
  const [exiting, setExiting] = useState(false);

  useEffect(() => {
    if (toast.type === "pending") return; // pending toasts don't auto-dismiss
    const timer = setTimeout(() => {
      setExiting(true);
      setTimeout(onRemove, 300);
    }, toast.duration ?? 5000);
    return () => clearTimeout(timer);
  }, [toast, onRemove]);

  const iconColor =
    toast.type === "success" ? "text-zk-green" :
    toast.type === "error" ? "text-red-400" :
    "text-latch-gold";

  const borderColor =
    toast.type === "success" ? "border-zk-green/20" :
    toast.type === "error" ? "border-red-500/20" :
    "border-latch-gold/20";

  return (
    <div
      className={`flex items-start gap-3 p-4 rounded-lg bg-slate/90 backdrop-blur-sm border ${borderColor}
        shadow-[0_8px_32px_-8px_rgba(0,0,0,0.6)] transition-all duration-300
        ${exiting ? "opacity-0 translate-x-4" : "opacity-100 translate-x-0"}`}
      style={{ minWidth: 320, maxWidth: 400 }}
    >
      {/* Icon */}
      <div className={`mt-0.5 ${iconColor}`}>
        {toast.type === "pending" && (
          <svg className="w-4 h-4 animate-spin" viewBox="0 0 24 24" fill="none">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
          </svg>
        )}
        {toast.type === "success" && (
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
        )}
        {toast.type === "error" && (
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        )}
      </div>

      {/* Content */}
      <div className="flex-1 min-w-0">
        <p className="text-xs font-medium text-starlight">{toast.title}</p>
        {toast.message && (
          <p className="mt-0.5 text-[11px] text-mist/60 truncate">{toast.message}</p>
        )}
        {toast.txHash && (
          <p className="mt-1 text-[10px] font-mono text-mist/40 truncate">
            tx: {toast.txHash.slice(0, 10)}...{toast.txHash.slice(-6)}
          </p>
        )}
      </div>

      {/* Dismiss */}
      <button onClick={() => { setExiting(true); setTimeout(onRemove, 300); }} className="text-mist/30 hover:text-mist/60">
        <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
  );
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = useCallback((toast: Omit<Toast, "id">) => {
    const id = ++nextId;
    setToasts((prev) => [...prev, { ...toast, id }]);
    return id;
  }, []);

  const removeToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  return (
    <ToastContext.Provider value={{ addToast }}>
      {children}
      {/* Toast container — bottom right */}
      <div className="fixed bottom-6 right-6 z-50 flex flex-col gap-2">
        {toasts.map((toast) => (
          <ToastItem key={toast.id} toast={toast} onRemove={() => removeToast(toast.id)} />
        ))}
      </div>
    </ToastContext.Provider>
  );
}
