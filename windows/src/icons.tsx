import { CloudFile, isFolder } from "./api";

type Kind = { color: string; label: string };

function kindOf(f: CloudFile): Kind {
  const ext = (f.fileSuffix || f.fileName.split(".").pop() || "").toLowerCase();
  const t = f.fileType || "";
  if (t === "PICTURE" || /^(jpe?g|png|gif|webp|heic|bmp|svg)$/.test(ext)) return { color: "#8a5cf6", label: "IMG" };
  if (t === "VIDEO" || /^(mp4|mov|mkv|avi|webm)$/.test(ext)) return { color: "#e5484d", label: "VID" };
  if (t === "AUDIO" || /^(mp3|wav|m4a|flac|aac|ogg)$/.test(ext)) return { color: "#f76b15", label: "AUD" };
  if (ext === "pdf") return { color: "#d13438", label: "PDF" };
  if (t === "WORD" || /^(docx?|odt|rtf)$/.test(ext)) return { color: "#185abd", label: "DOC" };
  if (t === "EXCEL" || /^(xlsx?|ods|csv)$/.test(ext)) return { color: "#107c41", label: "XLS" };
  if (t === "PPT" || /^(pptx?|odp)$/.test(ext)) return { color: "#c43e1c", label: "PPT" };
  if (t === "ARCHIVE" || /^(zip|rar|7z|tar|gz)$/.test(ext)) return { color: "#8e6c29", label: "ZIP" };
  if (/^(txt|md|log)$/.test(ext)) return { color: "#5e6b7a", label: "TXT" };
  return { color: "#6b7785", label: (ext || "FILE").slice(0, 4).toUpperCase() };
}

export function FolderGlyph({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M2.5 6.5a2 2 0 0 1 2-2h4.6l2 2H19.5a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2z" fill="#f4b740" />
      <path d="M2.5 9h19v8.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2z" fill="#ffcf5c" />
    </svg>
  );
}

export function FileGlyph({ file, size = 20 }: { file: CloudFile; size?: number }) {
  if (isFolder(file)) return <FolderGlyph size={size} />;
  const k = kindOf(file);
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 2.5h8l5 5V20a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 20V4a1.5 1.5 0 0 1 1-1.5z" fill="#fff" stroke="#c8ced6" />
      <path d="M14 2.5V7a.5.5 0 0 0 .5.5H19" fill="none" stroke="#c8ced6" />
      <rect x="3" y="12" width="14" height="7" rx="1.5" fill={k.color} />
      <text x="10" y="17.4" text-anchor="middle" font-size="5" font-weight="700" fill="#fff" font-family="Segoe UI, sans-serif">{k.label}</text>
    </svg>
  );
}

/** Small monochrome UI icons (Fluent-style strokes). */
export function Icon({ name, size = 16 }: { name: string; size?: number }) {
  const p: Record<string, string> = {
    drive: "M3 15.5h18M5 5h14l2 10.5v3A1.5 1.5 0 0 1 19.5 20h-15A1.5 1.5 0 0 1 3 18.5v-3zM17 18h.01",
    recent: "M12 7v5l3 2M21 12a9 9 0 1 1-9-9 9 9 0 0 1 9 9z",
    star: "M12 3.5l2.6 5.3 5.8.8-4.2 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.2-4.1 5.8-.8z",
    trash: "M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5",
    back: "M15 18l-6-6 6-6",
    plus: "M12 5v14M5 12h14",
    upload: "M12 16V4M7 9l5-5 5 5M4 20h16",
    folderPlus: "M3 6.5a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM12 10v6M9 13h6",
    grid: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
    list: "M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01",
    refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
    search: "M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14zM21 21l-5-5",
    sort: "M7 4v16M3 16l4 4 4-4M17 20V4M13 8l4-4 4 4",
    more: "M5 12h.01M12 12h.01M19 12h.01",
    close: "M6 6l12 12M18 6L6 18",
    chevronDown: "M6 9l6 6 6-6",
    chevronUp: "M6 15l6-6 6 6",
    chevronRight: "M9 6l6 6-6 6",
    cloud: "M7 18a5 5 0 0 1-.6-10A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9z",
    check: "M5 12l5 5 9-10",
    alert: "M12 8v5M12 16h.01M10.3 3.9L2.5 18a2 2 0 0 0 1.7 3h15.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z",
    download: "M12 4v12M7 11l5 5 5-5M4 20h16",
    folderOpen: "M3 7a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v1H7.5L5 19H5a2 2 0 0 1-2-2zM5 19l2.5-9H22l-2.5 9z",
    user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
  };
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"
      stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d={p[name] || ""} />
    </svg>
  );
}
