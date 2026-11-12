import { invoke } from "@tauri-apps/api/core";

export interface DownloadLink { usage?: string; downloadLink?: string }

export interface CloudFile {
  id: string;
  fileName: string;
  fileType?: string;
  fileSuffix?: string;
  mimeType?: string;
  parentFolder?: string[];
  fileSize?: number;
  recycled?: boolean;
  favorite?: boolean;
  createdTime?: string;
  editedTime?: string;
  downloadLinks?: DownloadLink[];
}

export interface SpaceInfo { cloudUserId?: string; capacity?: number; spaceUsed?: number }
export interface Profile { name?: string; firstName?: string; lastName?: string; mobileNumber?: string; userName?: string; email?: string }
export interface Account { space: SpaceInfo; profile: Profile }

export type Section = "myDrive" | "recent" | "starred" | "trash";

export interface Transfer {
  id: string;
  name: string;
  kind: "upload" | "download";
  size: number;
  status: "queued" | "hashing" | "transferring" | "finishing" | "done" | "failed" | "cancelled";
  fraction: number;
  message?: string;
  localPath?: string;
}

export const FOLDER_MIME = "application/vnd.huawei-apps.folder";
export const isFolder = (f: CloudFile) => f.mimeType === FOLDER_MIME || f.fileType === "FOLDER";
export const thumbnailOf = (f: CloudFile) => f.downloadLinks?.find((l) => l.usage === "thumbnail")?.downloadLink;
export const isActive = (t: Transfer) => ["queued", "hashing", "transferring", "finishing"].includes(t.status);

/** Name without its extension (rename takes the base name; the server keeps the suffix). */
export function baseName(f: CloudFile): string {
  const s = f.fileSuffix;
  if (isFolder(f) || !s || !f.fileName.endsWith("." + s)) return f.fileName;
  return f.fileName.slice(0, -(s.length + 1));
}

/** File timestamps are UTC without a zone suffix. */
export function parseTime(s?: string): Date | undefined {
  if (!s) return undefined;
  const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : s + "Z");
  return isNaN(d.getTime()) ? undefined : d;
}

export const modifiedOf = (f: CloudFile) => parseTime(f.editedTime) ?? parseTime(f.createdTime);

export function displayName(p?: Profile): string {
  if (!p) return "GP Cloud";
  if (p.name) return p.name;
  const full = [p.firstName, p.lastName].filter(Boolean).join(" ");
  return full || p.mobileNumber || p.userName || "GP Cloud";
}

/** Server rule: ^(?!\.{1,2}$)(?!.*[<>|:"*?\/\s]).{1,250}$ */
export function nameError(name: string): string | null {
  if (!name) return "Name can't be empty.";
  if (name === "." || name === "..") return 'Name can\'t be "." or "..".';
  if ([...name].length > 250) return "Name must be 250 characters or fewer.";
  if (/\s/.test(name)) return "GP Cloud doesn't allow spaces in names.";
  if (/[<>|:"*?/\\]/.test(name)) return 'Name can\'t contain < > | : " * ? / \\';
  return null;
}
export const sanitizeName = (n: string) => n.replace(/\s/g, "_").replace(/[<>|:"*?/\\]/g, "") || "untitled";

export const api = {
  authState: () => invoke<{ signedIn: boolean; error?: string }>("auth_state"),
  startLogin: () => invoke<void>("start_login"),
  signOut: () => invoke<void>("sign_out"),
  account: () => invoke<Account>("account"),
  listFiles: (section: Section, folderId: string, search: string) =>
    invoke<CloudFile[]>("list_files", { section, folderId, search }),
  listFolders: (parentId: string) => invoke<CloudFile[]>("list_folders", { parentId }),
  createFolder: (name: string, parentId: string) => invoke<void>("create_folder", { name, parentId }),
  rename: (id: string, newName: string) => invoke<void>("rename_file", { id, newName }),
  move: (ids: string[], dest: string) => invoke<void>("move_files", { ids, dest }),
  copy: (ids: string[], dest: string) => invoke<void>("copy_files", { ids, dest }),
  trash: (files: CloudFile[], permanent: boolean) => invoke<void>("trash_files", { files, permanent }),
  restore: (ids: string[]) => invoke<void>("restore_files", { ids }),
  emptyTrash: () => invoke<void>("empty_trash"),
  setStar: (ids: string[], on: boolean) => invoke<void>("set_star", { ids, on }),
  publicLink: (id: string) => invoke<string>("public_link", { id }),
  upload: (paths: string[], folderId: string) => invoke<void>("upload", { paths, folderId }),
  download: (files: CloudFile[], dir: string | null) => invoke<void>("download", { files, dir }),
  cancelTransfer: (id: string) => invoke<void>("cancel_transfer", { id }),
  openFile: (file: CloudFile) => invoke<void>("open_file", { file }),
  reveal: (path: string) => invoke<void>("reveal", { path }),
};

export function formatBytes(n?: number): string {
  if (n == null) return "—";
  if (n < 1000) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = n;
  let i = -1;
  do { v /= 1000; i++; } while (v >= 1000 && i < units.length - 1);
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

export function formatDate(d?: Date): string {
  if (!d) return "—";
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  if (d.getFullYear() === now.getFullYear()) return d.toLocaleDateString([], { month: "short", day: "numeric" });
  return d.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
}

export function errorText(e: unknown): string {
  return typeof e === "string" ? e : e instanceof Error ? e.message : JSON.stringify(e);
}
