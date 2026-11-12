import { useCallback, useEffect, useMemo, useRef, useState } from "preact/hooks";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Account, CloudFile, Section, Transfer, api, errorText, isActive, isFolder, modifiedOf,
} from "./api";
import {
  ConfirmDialog, ContextMenu, EmptyState, FolderPicker, GridView, ListView, MenuItem, NameDialog, Sidebar,
  TransfersPanel, Welcome,
} from "./components";
import { Icon } from "./icons";

type Crumb = { id: string; name: string };
type SortKey = "name" | "modified" | "size";
type Dialog =
  | { kind: "name"; file?: CloudFile }
  | { kind: "pick"; op: "move" | "copy"; files: CloudFile[] }
  | { kind: "confirm"; title: string; message: string; confirm: string; action: () => void };

const ROOT: Crumb = { id: "root", name: "My Drive" };
const store = {
  get: (k: string, d: string) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* ignore */ } },
};

export function App() {
  const [auth, setAuth] = useState<"checking" | "signedOut" | "signedIn">("checking");
  const [authError, setAuthError] = useState<string>();

  const checkAuth = useCallback(async () => {
    setAuth("checking");
    setAuthError(undefined);
    try {
      const s = await api.authState();
      setAuth(s.signedIn ? "signedIn" : "signedOut");
      setAuthError(s.error);
    } catch (e) {
      setAuth("signedOut");
      setAuthError(errorText(e));
    }
  }, []);

  useEffect(() => {
    checkAuth();
    const un = listen<boolean>("auth-changed", (e) => { if (e.payload) setAuth("signedIn"); else checkAuth(); });
    return () => { un.then((f) => f()); };
  }, []);

  if (auth !== "signedIn") {
    return <Welcome checking={auth === "checking"} error={authError} onRetry={checkAuth}
      onSignIn={() => api.startLogin().catch((e) => setAuthError(errorText(e)))} />;
  }
  return <Drive onSignedOut={() => setAuth("signedOut")} />;
}

function Drive({ onSignedOut }: { onSignedOut: () => void }) {
  const [account, setAccount] = useState<Account>();
  const [section, setSection] = useState<Section>("myDrive");
  const [path, setPath] = useState<Crumb[]>([ROOT]);
  const [items, setItems] = useState<CloudFile[]>([]);
  const [itemsFromTrash, setItemsFromTrash] = useState(false);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState("");
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [anchor, setAnchor] = useState<string | null>(null);
  const [view, setView] = useState<"grid" | "list">(store.get("view", "grid") as "grid" | "list");
  const [sortKey, setSortKey] = useState<SortKey>(store.get("sortKey", "name") as SortKey);
  const [sortAsc, setSortAsc] = useState(store.get("sortAsc", "1") === "1");
  const [menu, setMenu] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [toast, setToast] = useState<{ text: string; error?: boolean } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [transfers, setTransfers] = useState<Map<string, Transfer>>(new Map());
  const [panel, setPanel] = useState(false);
  const [dropOver, setDropOver] = useState(false);
  const loadGen = useRef(0);
  const searchBox = useRef<HTMLInputElement>(null);

  const folderId = path[path.length - 1].id;
  const searching = search.trim().length > 0;
  const canCreate = section === "myDrive" && !searching;

  // Latest values for event listeners registered once.
  const live = useRef({ folderId, canCreate, section });
  live.current = { folderId, canCreate, section };

  const showError = (e: unknown) => setToast({ text: errorText(e), error: true });
  const flash = (text: string) => setToast({ text });

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), toast.error ? 6000 : 2500);
    return () => clearTimeout(t);
  }, [toast]);

  const refreshAccount = useCallback(() => {
    api.account().then(setAccount).catch(() => {});
  }, []);

  const load = useCallback(async (opts?: { quiet?: boolean }) => {
    const gen = ++loadGen.current;
    if (!opts?.quiet) setLoading(true);
    try {
      const result = await api.listFiles(section, folderId, search);
      if (gen !== loadGen.current) return;
      setItems(result);
      setItemsFromTrash(section === "trash");
      setSelection((s) => new Set([...s].filter((id) => result.some((f) => f.id === id))));
    } catch (e) {
      if (gen !== loadGen.current) return;
      const msg = errorText(e);
      if (msg.includes("signed out")) { onSignedOut(); return; }
      showError(e);
    } finally {
      if (gen === loadGen.current) setLoading(false);
    }
  }, [section, folderId, search]);

  // Reload when location changes (debounced for search typing).
  useEffect(() => {
    const t = setTimeout(() => load(), searching ? 350 : 0);
    return () => clearTimeout(t);
  }, [load]);

  useEffect(() => { refreshAccount(); }, []);

  // Backend events.
  useEffect(() => {
    let refreshTimer: number | undefined;
    const subs = [
      listen<Transfer>("transfer", (e) => {
        setTransfers((m) => new Map(m).set(e.payload.id, e.payload));
        setPanel(true);
      }),
      listen<string>("files-changed", () => {
        clearTimeout(refreshTimer);
        refreshTimer = window.setTimeout(() => { load({ quiet: true }); refreshAccount(); }, 1200);
      }),
      listen("show-transfers", () => setPanel(true)),
      getCurrentWebview().onDragDropEvent((e) => {
        const p = e.payload;
        if (p.type === "enter" || p.type === "over") setDropOver(live.current.canCreate);
        else if (p.type === "leave") setDropOver(false);
        else if (p.type === "drop") {
          setDropOver(false);
          if (live.current.canCreate && p.paths.length) api.upload(p.paths, live.current.folderId).catch(showError);
          else if (p.paths.length) flash("Open a folder in My Drive to upload there.");
        }
      }),
    ];
    return () => { clearTimeout(refreshTimer); subs.forEach((s) => s.then((f) => f())); };
  }, [load]);

  const sorted = useMemo(() => {
    if (section === "recent" && !searching) return items;
    const dir = sortAsc ? 1 : -1;
    return [...items].sort((a, b) => {
      const fa = isFolder(a), fb = isFolder(b);
      if (fa !== fb) return fa ? -1 : 1;
      let c = 0;
      if (sortKey === "name") c = a.fileName.localeCompare(b.fileName, undefined, { numeric: true, sensitivity: "base" });
      else if (sortKey === "modified") c = (modifiedOf(a)?.getTime() ?? 0) - (modifiedOf(b)?.getTime() ?? 0);
      else c = (a.fileSize ?? 0) - (b.fileSize ?? 0);
      return c * dir;
    });
  }, [items, sortKey, sortAsc, section, searching]);

  const selected = sorted.filter((f) => selection.has(f.id));

  // MARK: navigation

  const clearListing = () => { setItems([]); setSelection(new Set()); setItemsFromTrash(false); };

  const goSection = (s: Section) => {
    if (s === section && !searching && path.length === 1) return;
    clearListing();
    setSearch("");
    setSection(s);
    setPath([ROOT]);
  };

  const openItem = (f: CloudFile) => {
    if (itemsFromTrash || f.recycled) return;
    if (isFolder(f)) {
      clearListing();
      const base = section !== "myDrive" || searching ? [ROOT] : path;
      setSearch("");
      setSection("myDrive");
      setPath([...base, { id: f.id, name: f.fileName }]);
    } else {
      setBusy(`Opening ${f.fileName}…`);
      api.openFile(f).catch(showError).finally(() => setBusy(null));
    }
  };

  const goTo = (i: number) => { if (i < path.length - 1) { clearListing(); setPath(path.slice(0, i + 1)); } };
  const goUp = () => { if (section === "myDrive" && !searching && path.length > 1) goTo(path.length - 2); };

  // MARK: selection

  const onSelect = (f: CloudFile, e: MouseEvent) => {
    if (e.shiftKey && anchor) {
      const a = sorted.findIndex((x) => x.id === anchor), b = sorted.findIndex((x) => x.id === f.id);
      if (a >= 0 && b >= 0) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelection(new Set(sorted.slice(lo, hi + 1).map((x) => x.id)));
        return;
      }
    }
    if (e.ctrlKey || e.metaKey) {
      const s = new Set(selection);
      s.has(f.id) ? s.delete(f.id) : s.add(f.id);
      setSelection(s);
    } else {
      setSelection(new Set([f.id]));
    }
    setAnchor(f.id);
  };

  // MARK: actions

  const run = async (label: string | null, op: () => Promise<unknown>, after?: () => void) => {
    setBusy(label);
    try { await op(); after?.(); } catch (e) { showError(e); }
    finally { setBusy(null); await load({ quiet: true }); }
  };

  const chooseUpload = async (folders: boolean) => {
    if (!canCreate) return;
    const picked = await open({ multiple: true, directory: folders, title: folders ? "Upload folders" : "Upload files" });
    const paths = Array.isArray(picked) ? picked : picked ? [picked] : [];
    if (paths.length) api.upload(paths, folderId).catch(showError);
  };

  const downloadTo = async (files: CloudFile[], ask: boolean) => {
    let dir: string | null = null;
    if (ask) {
      const picked = await open({ directory: true, title: "Download to" });
      if (!picked || Array.isArray(picked)) return;
      dir = picked;
    }
    api.download(files.filter((f) => !isFolder(f)), dir).catch(showError);
  };

  const trashOrDelete = (files: CloudFile[]) => {
    if (!files.length) return;
    if (itemsFromTrash) {
      setDialog({
        kind: "confirm", title: `Delete ${describe(files)} forever?`, message: "This can't be undone.", confirm: "Delete forever",
        action: () => run("Deleting…", () => api.trash(files, true), refreshAccount),
      });
    } else {
      run("Moving to Trash…", () => api.trash(files, false), refreshAccount);
    }
  };

  const menuFor = (files: CloudFile[]): MenuItem[] => {
    const one = files.length === 1 ? files[0] : null;
    const plain = files.filter((f) => !isFolder(f));
    if (itemsFromTrash) {
      return [
        { label: "Restore", action: () => run("Restoring…", () => api.restore(files.map((f) => f.id)), refreshAccount) },
        { label: "Delete forever…", danger: true, action: () => trashOrDelete(files) },
      ];
    }
    const allStarred = files.every((f) => f.favorite);
    const m: MenuItem[] = [];
    if (one) m.push({ label: "Open", shortcut: "Enter", action: () => openItem(one) }, { separator: true, label: "", action: () => {} });
    if (plain.length) {
      m.push({ label: plain.length > 1 ? `Download ${plain.length} files` : "Download", action: () => downloadTo(plain, false) });
      m.push({ label: "Download to…", action: () => downloadTo(plain, true) });
    }
    if (one) m.push({ label: "Rename…", shortcut: "F2", action: () => setDialog({ kind: "name", file: one }) });
    m.push({ label: allStarred ? "Remove from Starred" : "Add to Starred", action: () => run(null, () => api.setStar(files.map((f) => f.id), !allStarred)) });
    m.push({ separator: true, label: "", action: () => {} });
    m.push({ label: "Move to…", action: () => setDialog({ kind: "pick", op: "move", files }) });
    m.push({ label: "Copy to…", action: () => setDialog({ kind: "pick", op: "copy", files }) });
    if (one && !isFolder(one)) m.push({
      label: "Copy public link",
      action: () => run("Creating link…", async () => { await navigator.clipboard.writeText(await api.publicLink(one.id)); }, () => flash("Link copied")),
    });
    m.push({ separator: true, label: "", action: () => {} });
    m.push({ label: "Move to Trash", shortcut: "Del", danger: true, action: () => trashOrDelete(files) });
    return m;
  };

  const onMenu = (f: CloudFile, e: MouseEvent) => {
    const targets = selection.has(f.id) ? selected : [f];
    if (!selection.has(f.id)) { setSelection(new Set([f.id])); setAnchor(f.id); }
    setMenu({ x: e.clientX, y: e.clientY, items: menuFor(targets) });
  };

  const newMenu = (e: MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    setMenu({
      x: r.left, y: r.bottom + 4,
      items: [
        { label: "New folder", shortcut: "Ctrl+Shift+N", action: () => setDialog({ kind: "name" }) },
        { separator: true, label: "", action: () => {} },
        { label: "Upload files…", shortcut: "Ctrl+U", action: () => chooseUpload(false) },
        { label: "Upload folder…", action: () => chooseUpload(true) },
      ],
    });
  };

  const sortMenu = (e: MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const pick = (k: SortKey) => { setSortKey(k); store.set("sortKey", k); };
    const order = (asc: boolean) => { setSortAsc(asc); store.set("sortAsc", asc ? "1" : "0"); };
    const mark = (on: boolean, t: string) => (on ? "✓  " : "     ") + t;
    setMenu({
      x: r.left, y: r.bottom + 4,
      items: [
        { label: mark(sortKey === "name", "Name"), action: () => pick("name") },
        { label: mark(sortKey === "modified", "Last modified"), action: () => pick("modified") },
        { label: mark(sortKey === "size", "Size"), action: () => pick("size") },
        { separator: true, label: "", action: () => {} },
        { label: mark(sortAsc, "Ascending"), action: () => order(true) },
        { label: mark(!sortAsc, "Descending"), action: () => order(false) },
      ],
    });
  };

  // MARK: keyboard

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement)?.closest?.("input, textarea") != null;
      if (dialog || menu) return;
      const ctrl = e.ctrlKey || e.metaKey;
      if (ctrl && e.key.toLowerCase() === "f") { e.preventDefault(); searchBox.current?.focus(); return; }
      if (e.key === "F5" || (ctrl && e.key.toLowerCase() === "r")) { e.preventDefault(); load(); refreshAccount(); return; }
      if (ctrl && e.shiftKey && e.key.toLowerCase() === "n") { e.preventDefault(); if (canCreate) setDialog({ kind: "name" }); return; }
      if (ctrl && e.key.toLowerCase() === "u") { e.preventDefault(); chooseUpload(false); return; }
      if (typing) return;
      if (ctrl && e.key.toLowerCase() === "a") { e.preventDefault(); setSelection(new Set(sorted.map((f) => f.id))); return; }
      if (e.key === "Escape") { setSelection(new Set()); return; }
      if (e.key === "Delete") { trashOrDelete(selected); return; }
      if (e.key === "F2" && selected.length === 1 && !itemsFromTrash) { setDialog({ kind: "name", file: selected[0] }); return; }
      if (e.key === "Enter" && selected.length === 1) { openItem(selected[0]); return; }
      if (e.key === "Backspace" || (e.altKey && e.key === "ArrowUp")) { e.preventDefault(); goUp(); return; }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // MARK: render

  const transferList = [...transfers.values()].reverse();
  const title = searching ? `Results for “${search.trim()}”` : section === "myDrive" ? null : ({ recent: "Recent", starred: "Starred", trash: "Trash" } as const)[section];
  const viewProps = { items: sorted, selection, onSelect, onOpen: openItem, onMenu, onBackground: () => setSelection(new Set()) };

  return (
    <div class="app">
      <Sidebar section={section} onSection={goSection} account={account} onNew={canCreate ? newMenu : undefined}
        onSignOut={() => setDialog({
          kind: "confirm", title: "Sign out of GP Cloud?", message: "Transfers in progress will stop.", confirm: "Sign out",
          action: () => api.signOut().then(onSignedOut),
        })} />
      <main class="main">
        <header class="toolbar">
          <button class="icon-btn" title="Up (Alt+↑)" disabled={section !== "myDrive" || searching || path.length <= 1} onClick={goUp}><Icon name="back" /></button>
          <div class="crumbs">
            {title ? <span class="crumb current">{title}</span> : path.map((c, i) => (
              <span key={c.id} class="crumb">
                {i > 0 && <Icon name="chevronRight" size={14} />}
                <button class={"link-plain" + (i === path.length - 1 ? " current" : "")} onClick={() => goTo(i)}>{c.name}</button>
              </span>
            ))}
          </div>
          <div class="search">
            <Icon name="search" />
            <input ref={searchBox} placeholder="Search in GP Cloud" value={search}
              onInput={(e) => { clearListing(); setSearch((e.target as HTMLInputElement).value); }} />
            {search && <button class="icon-btn" onClick={() => { clearListing(); setSearch(""); }}><Icon name="close" size={14} /></button>}
          </div>
          {section === "trash" && itemsFromTrash && items.length > 0 && (
            <button class="btn" onClick={() => setDialog({
              kind: "confirm", title: "Empty Trash?", message: "All items in Trash will be deleted forever. This can't be undone.", confirm: "Empty Trash",
              action: () => run("Emptying Trash…", () => api.emptyTrash(), refreshAccount),
            })}>Empty Trash</button>
          )}
          <button class="icon-btn" title="Sort" onClick={(e) => sortMenu(e as unknown as MouseEvent)}><Icon name="sort" /></button>
          <div class="segmented">
            <button class={view === "grid" ? "on" : ""} title="Grid" onClick={() => { setView("grid"); store.set("view", "grid"); }}><Icon name="grid" /></button>
            <button class={view === "list" ? "on" : ""} title="List" onClick={() => { setView("list"); store.set("view", "list"); }}><Icon name="list" /></button>
          </div>
          <button class="icon-btn" title="Refresh (F5)" onClick={() => { load(); refreshAccount(); }}><Icon name="refresh" /></button>
        </header>
        <div class="statusbar">
          <span>{busy ?? (loading && items.length ? "Loading…" : "")}</span>
          <span class="muted">{items.length} item{items.length === 1 ? "" : "s"}</span>
        </div>
        <section class="content">
          {loading && !items.length ? <div class="center"><div class="spinner" /></div>
            : !items.length ? <EmptyState section={section} searching={searching} onUpload={canCreate ? () => chooseUpload(false) : undefined} />
            : view === "grid" ? <GridView {...viewProps} /> : <ListView {...viewProps} />}
          {dropOver && <div class="drop-overlay"><div><Icon name="upload" size={28} /> Drop to upload to “{path[path.length - 1].name}”</div></div>}
        </section>
      </main>

      {panel && transferList.length > 0 && (
        <TransfersPanel transfers={transferList} onClose={() => setPanel(false)}
          onClear={() => setTransfers((m) => new Map([...m].filter(([, t]) => isActive(t))))} />
      )}
      {menu && <ContextMenu {...menu} onClose={() => setMenu(null)} />}
      {dialog?.kind === "name" && (
        <NameDialog file={dialog.file} onClose={() => setDialog(null)}
          onSubmit={(name) => dialog.file
            ? run("Renaming…", () => api.rename(dialog.file!.id, name))
            : run("Creating folder…", () => api.createFolder(name, folderId))} />
      )}
      {dialog?.kind === "pick" && (
        <FolderPicker title={`${dialog.op === "move" ? "Move" : "Copy"} ${describe(dialog.files)} to…`}
          action={dialog.op === "move" ? "Move here" : "Copy here"}
          excluding={new Set(dialog.files.filter(isFolder).map((f) => f.id))}
          onClose={() => setDialog(null)}
          onPick={(dest) => run(dialog.op === "move" ? "Moving…" : "Copying…",
            () => dialog.op === "move" ? api.move(dialog.files.map((f) => f.id), dest) : api.copy(dialog.files.map((f) => f.id), dest),
            refreshAccount)} />
      )}
      {dialog?.kind === "confirm" && (
        <ConfirmDialog title={dialog.title} message={dialog.message} confirm={dialog.confirm} onConfirm={dialog.action} onClose={() => setDialog(null)} />
      )}
      {toast && <div class={"toast" + (toast.error ? " error" : "")} onClick={() => setToast(null)}>{toast.text}</div>}
    </div>
  );
}

function describe(files: CloudFile[]): string {
  return files.length === 1 ? `“${files[0].fileName}”` : `${files.length} items`;
}
