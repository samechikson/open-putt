import { useEffect, useState } from "react";
import {
  fetchPutters,
  createPutter,
  updatePutter,
  deletePutter,
  setActivePutter,
  putterSpec,
  type PutterRow,
  type PutterInput,
} from "./putters";

interface PuttersProps {
  onBack: () => void;
}

// The add/edit form's draft state. Numbers are kept as strings while editing
// (like the session metadata editor) and parsed on save.
interface Draft {
  id: string | null; // null = adding a new putter
  name: string;
  brand: string;
  model: string;
  length_in: string;
  lie_deg: string;
  grip: string;
}

const EMPTY_DRAFT: Draft = {
  id: null,
  name: "",
  brand: "",
  model: "",
  length_in: "",
  lie_deg: "",
  grip: "",
};

function draftFrom(p: PutterRow): Draft {
  return {
    id: p.id,
    name: p.name,
    brand: p.brand ?? "",
    model: p.model ?? "",
    length_in: p.length_in == null ? "" : String(p.length_in),
    lie_deg: p.lie_deg == null ? "" : String(p.lie_deg),
    grip: p.grip ?? "",
  };
}

export default function Putters({ onBack }: PuttersProps) {
  // undefined = loading, null = error, array = loaded.
  const [putters, setPutters] = useState<PutterRow[] | null | undefined>(
    undefined,
  );
  const [loadError, setLoadError] = useState<string | null>(null);

  // The add/edit form draft, or null when the form is closed.
  const [draft, setDraft] = useState<Draft | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  // Per-row pending flags (set active / delete) for disabling buttons.
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = () => {
    fetchPutters()
      .then(setPutters)
      .catch((e: unknown) => {
        setLoadError(e instanceof Error ? e.message : "Failed to load putters");
        setPutters(null);
      });
  };

  useEffect(load, []);

  const startAdd = () => {
    setSaveError(null);
    setDraft({ ...EMPTY_DRAFT });
  };
  const startEdit = (p: PutterRow) => {
    setSaveError(null);
    setDraft(draftFrom(p));
  };

  const parseOptionalNumber = (
    raw: string,
    label: string,
  ): { value: number | null } | { error: string } => {
    const trimmed = raw.trim();
    if (trimmed === "") return { value: null };
    const n = Number(trimmed);
    if (!Number.isFinite(n) || n < 0) {
      return { error: `${label} must be a non-negative number.` };
    }
    return { value: n };
  };

  const handleSave = async () => {
    if (!draft) return;
    const name = draft.name.trim();
    if (name === "") {
      setSaveError("Name is required.");
      return;
    }
    const length = parseOptionalNumber(draft.length_in, "Length");
    if ("error" in length) return setSaveError(length.error);
    const lie = parseOptionalNumber(draft.lie_deg, "Lie");
    if ("error" in lie) return setSaveError(lie.error);

    const fields: PutterInput = {
      name,
      brand: draft.brand.trim() || null,
      model: draft.model.trim() || null,
      length_in: length.value,
      lie_deg: lie.value,
      grip: draft.grip.trim() || null,
    };

    setSaving(true);
    setSaveError(null);
    try {
      if (draft.id == null) {
        await createPutter(fields);
      } else {
        await updatePutter(draft.id, fields);
      }
      setDraft(null);
      load();
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : "Could not save putter");
    } finally {
      setSaving(false);
    }
  };

  const handleSetActive = async (p: PutterRow) => {
    if (p.is_active) return;
    setBusyId(p.id);
    try {
      await setActivePutter(p.id);
      load();
    } catch (e) {
      setLoadError(
        e instanceof Error ? e.message : "Could not set active putter",
      );
    } finally {
      setBusyId(null);
    }
  };

  const handleDelete = async (p: PutterRow) => {
    if (
      !window.confirm(
        `Delete "${p.name}"? Sessions tagged with it will be un-tagged.`,
      )
    )
      return;
    setBusyId(p.id);
    try {
      await deletePutter(p.id);
      if (draft?.id === p.id) setDraft(null);
      load();
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : "Could not delete putter");
    } finally {
      setBusyId(null);
    }
  };

  const field = (
    label: string,
    key: keyof Omit<Draft, "id">,
    opts: { type?: string; placeholder?: string } = {},
  ) => (
    <label className="flex flex-col gap-1">
      <span className="text-sm text-[#aaa]">{label}</span>
      <input
        type={opts.type ?? "text"}
        {...(opts.type === "number" ? { min: 0, inputMode: "decimal" } : {})}
        value={draft?.[key] ?? ""}
        onChange={(e) =>
          setDraft((d) => (d ? { ...d, [key]: e.target.value } : d))
        }
        placeholder={opts.placeholder ?? "—"}
        className="bg-[#222] border border-[#333] focus:border-[#22c55e] rounded-lg text-sm text-white px-3 py-2 focus:outline-none"
      />
    </label>
  );

  return (
    <>
      <div className="flex items-center justify-between gap-4 mb-6">
        <h2 className="text-xl font-bold text-white">Your Putters</h2>
        <div className="flex items-center gap-2 shrink-0">
          {draft == null && (
            <button
              type="button"
              onClick={startAdd}
              className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
            >
              + Add Putter
            </button>
          )}
          <button
            type="button"
            onClick={onBack}
            className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
          >
            ← Sessions
          </button>
        </div>
      </div>

      {draft && (
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5 mb-6">
          <h3 className="text-xs font-semibold uppercase tracking-widest text-[#aaa] mb-3">
            {draft.id == null ? "Add Putter" : "Edit Putter"}
          </h3>
          <div className="flex flex-col gap-4">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              {field("Name", "name", { placeholder: "e.g. Gamer" })}
              {field("Grip", "grip", { placeholder: "e.g. SuperStroke" })}
              {field("Brand", "brand", { placeholder: "e.g. Scotty Cameron" })}
              {field("Model", "model", { placeholder: "e.g. Newport 2" })}
              {field("Length (inches)", "length_in", { type: "number" })}
              {field("Lie (degrees)", "lie_deg", { type: "number" })}
            </div>
            {saveError && <p className="text-sm text-[#f87171]">{saveError}</p>}
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={handleSave}
                disabled={saving}
                className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] disabled:opacity-50 rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
              >
                {saving ? "Saving…" : "Save"}
              </button>
              <button
                type="button"
                onClick={() => setDraft(null)}
                disabled={saving}
                className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] disabled:opacity-50 rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}

      {putters === undefined && (
        <div className="flex items-center gap-2 text-sm text-[#888]">
          <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
          Loading putters…
        </div>
      )}

      {putters === null && (
        <div className="bg-[#1a1a1a] border border-[#3a2020] rounded-xl p-5 text-sm text-[#f87171]">
          {loadError ?? "Failed to load putters."}
        </div>
      )}

      {putters && putters.length === 0 && draft == null && (
        <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-8 text-center">
          <p className="text-[#aaa] mb-4">
            No putters yet. Add the putter you're using so you can tag your
            sessions with it.
          </p>
          <button
            type="button"
            onClick={startAdd}
            className="px-4 py-2 bg-[#22c55e] hover:bg-[#16a34a] rounded-lg text-sm text-black font-semibold transition-all cursor-pointer"
          >
            + Add Putter
          </button>
        </div>
      )}

      {putters && putters.length > 0 && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {putters.map((p) => {
            const spec = putterSpec(p);
            const busy = busyId === p.id;
            return (
              <div
                key={p.id}
                className="bg-[#1a1a1a] border border-[#333] rounded-xl p-4 flex flex-col gap-3"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="text-white font-medium truncate">
                        {p.name}
                      </span>
                      {p.is_active && (
                        <span className="px-2 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide bg-[#1e3320] text-[#22c55e]">
                          Active
                        </span>
                      )}
                    </div>
                    {spec && (
                      <div className="text-xs text-[#888] mt-0.5 truncate">
                        {spec}
                      </div>
                    )}
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  {!p.is_active && (
                    <button
                      type="button"
                      onClick={() => handleSetActive(p)}
                      disabled={busy}
                      className="px-3 py-1.5 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] disabled:opacity-50 rounded-lg text-xs text-white font-medium transition-all cursor-pointer"
                    >
                      Set active
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => startEdit(p)}
                    disabled={busy}
                    className="px-3 py-1.5 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] disabled:opacity-50 rounded-lg text-xs text-white font-medium transition-all cursor-pointer"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    onClick={() => handleDelete(p)}
                    disabled={busy}
                    className="px-3 py-1.5 bg-[#2a1a1a] border border-[#4a2a2a] hover:bg-[#3a2020] disabled:opacity-50 rounded-lg text-xs text-[#f87171] font-medium transition-all cursor-pointer ml-auto"
                  >
                    {busy ? "…" : "Delete"}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
