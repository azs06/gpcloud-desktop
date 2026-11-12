import { useEffect, useRef, useState } from "preact/hooks";
import type { ComponentChildren } from "preact";
import {
  Account, CloudFile, Section, Transfer, api, baseName, displayName, errorText, formatBytes, formatDate,
  isActive, isFolder, modifiedOf, nameError, sanitizeName, thumbnailOf,
} from "./api";
import { FileGlyph, FolderGlyph, Icon } from "./icons";

// MARK: - Welcome

export function Welcome({ checking, error, onSignIn, onRetry }: { checking: boolean; error?: string; onSignIn: () => void; onRetry: () => void }) {
  return (
    <div class="welcome">
      <div class="welcome-card">
        <div class="logo"><Icon name="cloud" size={56} /></div>
        <h1>GP Cloud</h1>
        <p class="muted">Your Grameenphone cloud storage, on your desktop.</p>
        {checking ? <div class="spinner" /> : <button class="btn accent big" onClick={onSignIn}>Sign in</button>}
        {error && (
          <p class="error-text">{error} <button class="link" onClick={onRetry}>Try again</button></p>
        )}
        <p class="fine">You'll sign in on Grameenphone's own page. This app never sees your password.</p>
        <p class="fine">Unofficial client · not affiliated with or endorsed by Grameenphone</p>
      </div>
    </div>
  );
}

// MARK: - Sidebar

const SECTIONS: { id: Section; title: string; icon: string }[] = [
  { id: "myDrive", title: "My Drive", icon: "drive" },
  { id: "recent", title: "Recent", icon: "recent" },
  { id: "starred", title: "Starred", icon: "star" },
  { id: "trash", title: "Trash", icon: "trash" },
];

export function Sidebar({ section, onSection, account, onSignOut, onNew }: {
  section: Section; onSection: (s: Section) => void; account?: Account; onSignOut: () => void; onNew?: (e: MouseEvent) => void;
}) {
  const cap = account?.space.capacity ?? 0;
  const used = account?.space.spaceUsed ?? 0;
  const pct = cap > 0 ? Math.min(100, (used / cap) * 100) : 0;
  return (
    <aside class="sidebar">
      <div class="brand"><span class="brand-icon"><Icon name="cloud" size={22} /></span> GP Cloud</div>
      <button class="btn new-btn" disabled={!onNew} onClick={(e) => onNew?.(e as unknown as MouseEvent)}>
        <Icon name="plus" size={18} /> New
      </button>
      <nav>
        {SECTIONS.map((s) => (
          <button key={s.id} class={"nav-item" + (s.id === section ? " active" : "")} onClick={() => onSection(s.id)}>
            <Icon name={s.icon} size={18} /> {s.title}
          </button>
        ))}
      </nav>
      <div class="spacer" />
      <div class="storage">
        <div class="storage-label"><Icon name="cloud" size={14} /> Storage</div>
        <div class="meter"><div class={"meter-fill" + (pct > 90 ? " danger" : "")} style={{ width: `${pct}%` }} /></div>
        <div class="muted small">{cap ? `${formatBytes(used)} of ${formatBytes(cap)} used` : "—"}</div>
      </div>
      <div class="account">
        <span class="avatar"><Icon name="user" size={16} /></span>
        <div class="account-text">
          <div class="account-name">{displayName(account?.profile)}</div>
          {account?.profile.mobileNumber && account.profile.mobileNumber !== displayName(account.profile) &&
            <div class="muted small">{account.profile.mobileNumber}</div>}
        </div>
        <button class="icon-btn" title="Sign out" onClick={onSignOut}><Icon name="more" /></button>
      </div>
    </aside>
  );
}

// MARK: - File views

export interface ViewProps {
  items: CloudFile[];
  selection: Set<string>;
  onSelect: (f: CloudFile, e: MouseEvent) => void;
  onOpen: (f: CloudFile) => void;
  onMenu: (f: CloudFile, e: MouseEvent) => void;
  onBackground: () => void;
}

export function GridView({ items, selection, onSelect, onOpen, onMenu, onBackground }: ViewProps) {
  const folders = items.filter(isFolder);
  const files = items.filter((f) => !isFolder(f));
  const tile = (f: CloudFile, body: ComponentChildren, cls: string) => (
    <div
      key={f.id}
      class={cls + (selection.has(f.id) ? " selected" : "")}
      onClick={(e) => { e.stopPropagation(); onSelect(f, e as unknown as MouseEvent); }}
      onDblClick={(e) => { e.stopPropagation(); onOpen(f); }}
      onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); onMenu(f, e as unknown as MouseEvent); }}
      title={`${f.fileName}\n${isFolder(f) ? "" : formatBytes(f.fileSize) + " · "}${formatDate(modifiedOf(f))}`}
    >{body}</div>
  );
  return (
    <div class="scroll grid-wrap" onClick={onBackground} onContextMenu={(e) => e.preventDefault()}>
      {folders.length > 0 && <h3 class="group-title">Folders</h3>}
      <div class="folder-grid">
        {folders.map((f) => tile(f, <>
          <FolderGlyph size={22} /><span class="name">{f.fileName}</span>{f.favorite && <span class="star">★</span>}
        </>, "folder-chip"))}
      </div>
      {files.length > 0 && <h3 class="group-title">Files</h3>}
      <div class="file-grid">
        {files.map((f) => tile(f, <>
          <div class="preview">{thumbnailOf(f) ? <img src={thumbnailOf(f)} loading="lazy" alt="" /> : <FileGlyph file={f} size={56} />}</div>
          <div class="caption"><FileGlyph file={f} size={16} /><span class="name">{f.fileName}</span>{f.favorite && <span class="star">★</span>}</div>
        </>, "file-tile"))}
      </div>
    </div>
  );
}

export function ListView({ items, selection, onSelect, onOpen, onMenu, onBackground }: ViewProps) {
  return (
    <div class="scroll list-wrap" onClick={onBackground} onContextMenu={(e) => e.preventDefault()}>
      <table class="file-table">
        <thead><tr><th class="c-name">Name</th><th class="c-date">Last modified</th><th class="c-size">Size</th></tr></thead>
        <tbody>
          {items.map((f) => (
            <tr key={f.id} class={selection.has(f.id) ? "selected" : ""}
              onClick={(e) => { e.stopPropagation(); onSelect(f, e as unknown as MouseEvent); }}
              onDblClick={(e) => { e.stopPropagation(); onOpen(f); }}
              onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); onMenu(f, e as unknown as MouseEvent); }}>
              <td class="c-name"><FileGlyph file={f} size={18} /><span class="name">{f.fileName}</span>{f.favorite && <span class="star">★</span>}</td>
              <td class="c-date muted">{formatDate(modifiedOf(f))}</td>
              <td class="c-size muted">{isFolder(f) ? "—" : formatBytes(f.fileSize)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function EmptyState({ section, searching, onUpload }: { section: Section; searching: boolean; onUpload?: () => void }) {
  const text = searching
    ? ["No results", "Try a different search."]
    : ({
        myDrive: ["Drop files here", "Drag files or folders into this window, or use the Upload button."],
        recent: ["No recent files", "Files you open or upload will show up here."],
        starred: ["No starred files", "Star files and folders to find them quickly."],
        trash: ["Trash is empty", "Items you delete stay here until you empty the Trash."],
      } as const)[section];
  return (
    <div class="empty">
      <div class="empty-icon"><Icon name={searching ? "search" : section === "myDrive" ? "upload" : section === "recent" ? "recent" : section} size={44} /></div>
      <h2>{text[0]}</h2>
      <p class="muted">{text[1]}</p>
      {onUpload && <button class="btn accent" onClick={onUpload}>Upload files</button>}
    </div>
  );
}

// MARK: - Context menu

export interface MenuItem { label: string; action: () => void; danger?: boolean; separator?: boolean; shortcut?: string }

export function ContextMenu({ x, y, items, onClose }: { x: number; y: number; items: MenuItem[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x, y });
  useEffect(() => {
    const el = ref.current;
    if (el) {
      const r = el.getBoundingClientRect();
      setPos({ x: Math.min(x, window.innerWidth - r.width - 8), y: Math.min(y, window.innerHeight - r.height - 8) });
    }
    const close = () => onClose();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("mousedown", close);
    window.addEventListener("blur", close);
    window.addEventListener("keydown", key);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("blur", close); window.removeEventListener("keydown", key); };
  }, [x, y]);
  return (
    <div ref={ref} class="menu" style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()}>
      {items.map((it, i) => it.separator
        ? <div key={i} class="menu-sep" />
        : <button key={i} class={"menu-item" + (it.danger ? " danger" : "")} onClick={() => { onClose(); it.action(); }}>
            <span>{it.label}</span>{it.shortcut && <span class="shortcut">{it.shortcut}</span>}
          </button>)}
    </div>
  );
}

// MARK: - Dialogs

function Modal({ title, children, onClose, width = 420 }: { title: string; children: ComponentChildren; onClose: () => void; width?: number }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
  return (
    <div class="modal-backdrop" onMouseDown={onClose}>
      <div class="modal" style={{ width }} onMouseDown={(e) => e.stopPropagation()} role="dialog" aria-label={title}>
        <h2>{title}</h2>
        {children}
      </div>
    </div>
  );
}

export function NameDialog({ file, onSubmit, onClose }: { file?: CloudFile; onSubmit: (name: string) => void; onClose: () => void }) {
  const [name, setName] = useState(file ? baseName(file) : "Untitled-folder");
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { input.current?.focus(); input.current?.select(); }, []);
  const suffix = file && baseName(file) !== file.fileName ? file.fileSuffix : undefined;
  const err = name ? nameError(name) : null;
  const submit = () => { if (name && !err) { onSubmit(name); onClose(); } };
  return (
    <Modal title={file ? "Rename" : "New folder"} onClose={onClose}>
      <div class="field-row">
        <input ref={input} class="input" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)}
          onKeyDown={(e) => { if (e.key === "Enter") submit(); }} />
        {suffix && <span class="muted">.{suffix}</span>}
      </div>
      {err && <p class="warn"><Icon name="alert" size={14} /> {err}{/\s/.test(name) &&
        <> <button class="link" onClick={() => setName(sanitizeName(name))}>Replace spaces with underscores</button></>}</p>}
      <div class="modal-actions">
        <button class="btn" onClick={onClose}>Cancel</button>
        <button class="btn accent" disabled={!name || !!err} onClick={submit}>{file ? "Rename" : "Create"}</button>
      </div>
    </Modal>
  );
}

export function ConfirmDialog({ title, message, confirm, onConfirm, onClose }: { title: string; message: string; confirm: string; onConfirm: () => void; onClose: () => void }) {
  return (
    <Modal title={title} onClose={onClose}>
      <p class="muted">{message}</p>
      <div class="modal-actions">
        <button class="btn" onClick={onClose}>Cancel</button>
        <button class="btn danger" onClick={() => { onConfirm(); onClose(); }}>{confirm}</button>
      </div>
    </Modal>
  );
}

/** Browse folders to pick a Move/Copy destination. */
export function FolderPicker({ title, action, excluding, onPick, onClose }: {
  title: string; action: string; excluding: Set<string>; onPick: (folderId: string) => void; onClose: () => void;
}) {
  const [path, setPath] = useState([{ id: "root", name: "My Drive" }]);
  const [folders, setFolders] = useState<CloudFile[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const current = path[path.length - 1];
  useEffect(() => {
    let stale = false;
    setFolders(null); setSelected(null);
    api.listFolders(current.id)
      .then((f) => { if (!stale) setFolders(f.sort((a, b) => a.fileName.localeCompare(b.fileName, undefined, { numeric: true }))); })
      .catch((e) => { if (!stale) { setError(errorText(e)); setFolders([]); } });
    return () => { stale = true; };
  }, [current.id]);
  const dest = selected && !excluding.has(selected) ? selected : current.id;
  const destName = folders?.find((f) => f.id === selected)?.fileName ?? current.name;
  return (
    <Modal title={title} onClose={onClose} width={480}>
      <div class="crumbs small">
        <button class="icon-btn" disabled={path.length <= 1} onClick={() => setPath(path.slice(0, -1))}><Icon name="back" /></button>
        {path.map((c, i) => (
          <span key={c.id} class="crumb">
            {i > 0 && <Icon name="chevronRight" size={12} />}
            <button class="link-plain" onClick={() => setPath(path.slice(0, i + 1))}>{c.name}</button>
          </span>
        ))}
      </div>
      <div class="picker-list">
        {folders === null && <div class="spinner small" />}
        {folders?.length === 0 && <div class="muted pad">No folders here</div>}
        {folders?.map((f) => (
          <div key={f.id} class={"picker-row" + (selected === f.id ? " selected" : "") + (excluding.has(f.id) ? " disabled" : "")}
            onClick={() => !excluding.has(f.id) && setSelected(f.id)}
            onDblClick={() => !excluding.has(f.id) && setPath([...path, { id: f.id, name: f.fileName }])}>
            <FolderGlyph size={18} /> {f.fileName}
          </div>
        ))}
      </div>
      {error && <p class="error-text">{error}</p>}
      <div class="modal-actions spread">
        <span class="muted small">Destination: {destName}</span>
        <div>
          <button class="btn" onClick={onClose}>Cancel</button>
          <button class="btn accent" disabled={excluding.has(dest)} onClick={() => { onPick(dest); onClose(); }}>{action}</button>
        </div>
      </div>
    </Modal>
  );
}

// MARK: - Transfers panel

export function TransfersPanel({ transfers, onClose, onClear }: { transfers: Transfer[]; onClose: () => void; onClear: () => void }) {
  const [collapsed, setCollapsed] = useState(false);
  const active = transfers.filter(isActive).length;
  const failed = transfers.filter((t) => t.status === "failed").length;
  const head = active ? `Transferring ${active} item${active === 1 ? "" : "s"}`
    : failed ? `${failed} transfer${failed === 1 ? "" : "s"} failed`
    : `${transfers.length} transfer${transfers.length === 1 ? "" : "s"} complete`;
  return (
    <div class="transfers">
      <div class="transfers-head">
        <strong>{head}</strong>
        <div>
          <button class="icon-btn" onClick={() => setCollapsed(!collapsed)}><Icon name={collapsed ? "chevronUp" : "chevronDown"} /></button>
          <button class="icon-btn" onClick={() => { if (!active) onClear(); onClose(); }}><Icon name="close" /></button>
        </div>
      </div>
      {!collapsed && (
        <div class="transfers-list">
          {transfers.map((t) => <TransferRow key={t.id} t={t} />)}
        </div>
      )}
    </div>
  );
}

function TransferRow({ t }: { t: Transfer }) {
  const label: Record<Transfer["status"], string> = {
    queued: "Waiting…", hashing: "Preparing…", transferring: t.kind === "upload" ? "Uploading…" : "Downloading…",
    finishing: "Finishing…", done: t.message || (t.kind === "upload" ? "Uploaded" : "Downloaded"),
    failed: t.message || "Failed", cancelled: "Cancelled",
  };
  const busy = isActive(t);
  return (
    <div class="transfer-row">
      <span class={"transfer-kind " + t.kind}><Icon name={t.kind === "upload" ? "upload" : "download"} size={14} /></span>
      <div class="transfer-main">
        <div class="name" title={t.name}>{t.name}</div>
        {busy && <div class="bar"><div style={{ width: `${Math.round(t.fraction * 100)}%` }} /></div>}
        <div class={"small " + (t.status === "failed" ? "error-text" : "muted")}>
          {label[t.status]}{busy && t.size > 0 ? ` ${formatBytes(Math.round(t.size * t.fraction))} of ${formatBytes(t.size)}` : ""}
        </div>
      </div>
      {busy && <button class="icon-btn" title="Cancel" onClick={() => api.cancelTransfer(t.id)}><Icon name="close" size={14} /></button>}
      {t.status === "done" && t.kind === "download" && t.localPath &&
        <button class="icon-btn" title="Show in folder" onClick={() => api.reveal(t.localPath!)}><Icon name="folderOpen" size={15} /></button>}
      {t.status === "done" && t.kind === "upload" && <span class="ok"><Icon name="check" size={15} /></span>}
      {t.status === "failed" && <span class="error-text"><Icon name="alert" size={15} /></span>}
    </div>
  );
}
