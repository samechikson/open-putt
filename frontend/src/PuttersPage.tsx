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
    <div className="field">
      <label>{label}</label>
      <input
        className="input"
        type={opts.type ?? "text"}
        {...(opts.type === "number" ? { min: 0, inputMode: "decimal" } : {})}
        value={draft?.[key] ?? ""}
        onChange={(e) =>
          setDraft((d) => (d ? { ...d, [key]: e.target.value } : d))
        }
        placeholder={opts.placeholder ?? "—"}
      />
    </div>
  );

  const smallGhost = { padding: "6px 14px", fontSize: 13 } as const;

  return (
    <>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 16,
          marginBottom: 24,
        }}
      >
        <div style={{ fontFamily: "var(--font-heading)", fontSize: 24 }}>
          Your Putters
        </div>
        <div style={{ display: "flex", gap: 10, flexShrink: 0 }}>
          {draft == null && (
            <button type="button" onClick={startAdd} className="btn btn-primary">
              + Add Putter
            </button>
          )}
          <button type="button" onClick={onBack} className="btn btn-secondary">
            ← Sessions
          </button>
        </div>
      </div>

      {draft && (
        <div className="card elev-sm" style={{ marginBottom: 24 }}>
          <div className="kicker" style={{ marginBottom: 16 }}>
            {draft.id == null ? "Add Putter" : "Edit Putter"}
          </div>
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))",
              gap: 16,
              marginBottom: 16,
            }}
          >
            {field("Name", "name", { placeholder: "e.g. Gamer" })}
            {field("Grip", "grip", { placeholder: "e.g. SuperStroke" })}
            {field("Brand", "brand", { placeholder: "e.g. Scotty Cameron" })}
            {field("Model", "model", { placeholder: "e.g. Newport 2" })}
            {field("Length (inches)", "length_in", { type: "number" })}
            {field("Lie (degrees)", "lie_deg", { type: "number" })}
          </div>
          {saveError && (
            <p
              style={{
                margin: "0 0 12px",
                fontSize: 14,
                color: "var(--color-accent-800)",
              }}
            >
              {saveError}
            </p>
          )}
          <div style={{ display: "flex", gap: 10 }}>
            <button
              type="button"
              onClick={handleSave}
              disabled={saving}
              className="btn btn-primary"
            >
              {saving ? "Saving…" : "Save"}
            </button>
            <button
              type="button"
              onClick={() => setDraft(null)}
              disabled={saving}
              className="btn btn-ghost"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {putters === undefined && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            fontSize: 14,
            color: "var(--color-neutral-600)",
          }}
        >
          <span className="spinner" />
          Loading putters…
        </div>
      )}

      {putters === null && (
        <div
          className="card elev-sm"
          style={{ fontSize: 14, color: "var(--color-accent-800)" }}
        >
          {loadError ?? "Failed to load putters."}
        </div>
      )}

      {putters && putters.length === 0 && draft == null && (
        <div className="card elev-sm" style={{ padding: 32, textAlign: "center" }}>
          <p style={{ margin: "0 0 16px", color: "var(--color-neutral-700)" }}>
            No putters yet. Add the putter you're using so you can tag your
            sessions with it.
          </p>
          <button
            type="button"
            onClick={startAdd}
            className="btn btn-primary"
            style={{ alignSelf: "center" }}
          >
            + Add Putter
          </button>
        </div>
      )}

      {putters && putters.length > 0 && (
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))",
            gap: 14,
          }}
        >
          {putters.map((p) => {
            const spec = putterSpec(p);
            const busy = busyId === p.id;
            return (
              <div key={p.id} className="card elev-sm">
                <div
                  style={{ display: "flex", alignItems: "center", gap: 8 }}
                >
                  <span
                    style={{
                      fontWeight: 600,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {p.name}
                  </span>
                  {p.is_active && (
                    <span className="tag tag-accent-2" style={{ fontSize: 10 }}>
                      Active
                    </span>
                  )}
                </div>
                <div
                  style={{
                    fontSize: 13,
                    color: "var(--color-neutral-600)",
                    marginBottom: 16,
                    minHeight: 18,
                  }}
                >
                  {spec ?? " "}
                </div>
                <div style={{ display: "flex", gap: 8 }}>
                  {!p.is_active && (
                    <button
                      type="button"
                      onClick={() => handleSetActive(p)}
                      disabled={busy}
                      className="btn btn-ghost"
                      style={smallGhost}
                    >
                      Set active
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => startEdit(p)}
                    disabled={busy}
                    className="btn btn-ghost"
                    style={smallGhost}
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    onClick={() => handleDelete(p)}
                    disabled={busy}
                    className="btn btn-ghost"
                    style={{
                      ...smallGhost,
                      marginLeft: "auto",
                      color: "var(--color-accent-800)",
                    }}
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
