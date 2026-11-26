import { ArrowLeft, ArrowLeftRight, ChevronsRight, ListFilter, Printer, RefreshCw, RotateCcw, Settings2, Zap } from 'lucide-react';
import './SkipView.css';
import { panelTypes } from './panelTypes';
import { useState, useEffect, useRef, type FormEvent } from 'react';

type Station = { station: string; source: string; lastValidatedOrderId: number | null; lastValidatedSequence: number | null };
type Panel = {
  orderId: number; sequence: number; sd: string | null; reference: string;
  position: string | null; hand: string | null; productionDate: string; skipped: boolean; started: boolean;
};
type Pending = { station: Station; panels: Panel[]; nextCursor: number | null; sdOptions: string[] };
type Printing = { name: string; canConfigure: boolean; printers: string[]; counts: { estado: string; cantidad: number }[] };

async function call<T>(api: string, password: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${api}/api/salteo/${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Door-Supervisor': password },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.message || (response.status === 401
    ? 'La contraseña de supervisor es incorrecta.' : 'No se pudo consultar el salteo.'));
  return result as T;
}

const groupKey = (panel: Panel) => `${panel.productionDate}/${panel.sequence}`;
function groupPanels(panels: Panel[]) {
  const groups = new Map<string, Panel[]>();
  for (const panel of panels) {
    const key = groupKey(panel);
    const group = groups.get(key);
    if (group) group.push(panel);
    else groups.set(key, [panel]);
  }
  return groups;
}
const actionText = ['Saltear', 'Restaurar', 'Invertir'] as const;
type Action = { mode: 0 | 1 | 2; anchor?: Panel; entireSequence?: boolean; ids?: number[] };

export function SkipView({ apiBaseUrl, puesto, onClose }: {
  apiBaseUrl: string; puesto: string; onClose: () => void;
}) {
  const [password, setPassword] = useState('');
  const [stations, setStations] = useState<Station[] | null>(null);
  const [selected, setSelected] = useState('');
  const [pending, setPending] = useState<Pending | null>(null);
  const [action, setAction] = useState<Action | null>(null);
  const [marked, setMarked] = useState<number[]>([]);
  const [markedSequences, setMarkedSequences] = useState<Panel[]>([]);
  const [sdFilter, setSdFilter] = useState('');
  const confirmButton = useRef<HTMLButtonElement>(null);
  const [filter, setFilter] = useState('all');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [assignment, setAssignment] = useState<{ restricted: boolean; mask: number } | null>(null);
  const [printing, setPrinting] = useState<Printing | null>(null);
  const [printerName, setPrinterName] = useState('');

  const panels = pending?.panels ?? [];
  const skipped = panels.filter(panel => panel.skipped).length;
  const groups = [...groupPanels(panels)];
  const visible = panels.filter(panel => filter === 'all' ||
    (filter === 'pending' ? !panel.skipped : filter === 'skipped' ? panel.skipped : groupKey(panel) === filter));
  const visibleGroups = [...groupPanels(visible).values()];
  const markedPanels = panels.filter(panel => marked.includes(panel.orderId));
  const eligible = visible.filter(panel => !panel.started);
  const selectAll = () => {
    setMarkedSequences([]);
    setMarked(previous => [...new Set([...previous, ...eligible.map(panel => panel.orderId)])]);
  };

  useEffect(() => {
    if (action) confirmButton.current?.focus({ preventScroll: true });
  }, [action]);

  async function run(operation: () => Promise<void>) {
    setBusy(true); setError('');
    try { await operation(); }
    catch (failure) { setError(failure instanceof Error ? failure.message : 'Falló la operación.'); }
    finally { setBusy(false); }
  }

  async function load(station: string, after = 0, sd = sdFilter, keepSequences = false) {
    const page = await call<Pending>(apiBaseUrl, password,
      `pending?station=${encodeURIComponent(station)}&after=${after}&sd=${encodeURIComponent(sd)}`);
    setPending(previous => {
      if (!after || previous?.station.station !== station) return page;
      const valid = previous.panels.filter(panel =>
        page.station.lastValidatedOrderId == null || panel.orderId > page.station.lastValidatedOrderId);
      return { ...page, panels: [...valid, ...page.panels] };
    });
    if (!after) {
      setMarked([]); setFilter('all'); setSdFilter(sd);
      if (!keepSequences) setMarkedSequences([]);
    }
  }

  async function unlock(event: FormEvent) {
    event.preventDefault();
    await run(async () => {
      const options = await call<Station[]>(apiBaseUrl, password, 'stations');
      const station = options.find(item => item.station === puesto)?.station ?? options[0]?.station ?? '';
      setStations(options); setSelected(station);
      if (station) await load(station);
    });
  }

  async function save() {
    if (!action || !selected) return;
    await run(async () => {
      const result = await call<{ affected: number }>(apiBaseUrl, password, 'skip', {
        station: selected, mode: action.mode, orderId: action.anchor?.orderId ?? 0,
        entireSequence: action.entireSequence ?? false, orderIds: action.ids,
      });
      setAction(null);
      setNotice(result.affected === 0 ? 'La selección ya tenía ese estado.' :
        `${result.affected} ${result.affected === 1 ? 'panel actualizado' : 'paneles actualizados'} en ${selected}.`
        + (action.mode === 1 ? '' : ' Los paneles recién salteados quedaron en la cola de impresión.'));
      await load(selected);
      if (printing) await loadPrinting();
    });
  }

  async function openAssignment() {
    await run(async () => {
      const result = await call<{ mask: number }>(apiBaseUrl, password,
        `panel-assignment?station=${encodeURIComponent(selected)}`);
      setAction(null);
      setAssignment({ restricted: result.mask !== 0, mask: result.mask });
    });
  }

  async function saveAssignment() {
    if (!assignment) return;
    await run(async () => {
      await call(apiBaseUrl, password, 'panel-assignment', {
        station: selected, mask: assignment.restricted ? assignment.mask : 0,
      });
      setAssignment(null);
      setNotice(`Asignación de paneles guardada para ${selected}.`);
      await load(selected);
    });
  }

  async function loadPrinting() {
    const status = await call<Printing>(apiBaseUrl, password, `printing?station=${encodeURIComponent(selected)}`);
    setPrinterName(status.name);
    setPrinting(status);
  }

  const printCount = (state: string) => printing?.counts.find(count => count.estado === state)?.cantidad ?? 0;

  function filterButton(key: string, label: string) {
    return <button type="button" key={key} aria-pressed={filter === key} onClick={() => setFilter(key)}>{label}</button>;
  }

  return (
    <main className="skip-page">
      <header className="skip-header">
        <div className="skip-title"><h2>Salteo de Paneles</h2><span>Línea de ensamble de puertas</span></div>
        {stations && stations.length > 0 && <div className="skip-header-tools">
          <label>Puesto <select className="form-input" value={selected} disabled={busy} onChange={event => {
            const station = event.target.value;
            setSelected(station); setPending(null); setAction(null); setAssignment(null);
            setMarked([]); setMarkedSequences([]); setFilter('all'); setSdFilter(''); setPrinting(null); setNotice('');
            void run(() => load(station, 0, ''));
          }}>{stations.map(station => <option key={station.station}>{station.station}</option>)}</select></label>
          <button className="skip-button" disabled={busy} onClick={() => void run(() => load(selected))}><RefreshCw size={15} /> Actualizar</button>
          <button className="skip-button" disabled={busy} onClick={() => void openAssignment()}><Settings2 size={15} /> Paneles del puesto</button>
          <button className="skip-button" disabled={busy} onClick={() => void run(loadPrinting)}><Printer size={15} /> Impresión de Salteo</button>
          {pending && <span className="skip-last">Última validación <strong>
            {pending.station.lastValidatedSequence == null ? 'Sin validaciones' : `Secuencia ${pending.station.lastValidatedSequence}`}
          </strong></span>}
        </div>}
        <button className="skip-button skip-back" onClick={onClose}><ArrowLeft size={17} /> Volver a Operativo</button>
      </header>

      <div className="skip-content">
        {!stations ? (
          <form onSubmit={unlock} className="skip-login">
            <label>Contraseña de supervisor
              <input type="password" className="form-input" autoComplete="current-password" value={password}
                onChange={event => setPassword(event.target.value)} required />
            </label>
            <button className="skip-button skip-blue" disabled={busy}>Abrir Salteo</button>
          </form>
        ) : stations.length === 0 ? <p>No hay puestos habilitados para el salteo.</p> : pending && <>
          <section className="skip-banner" data-active={skipped > 0}>
            <div className="skip-banner-copy"><div className="skip-bolt"><Zap size={26} fill="currentColor" aria-hidden="true" /></div>
              <div><h3>{skipped} {skipped === 1 ? 'panel salteado' : 'paneles salteados'}</h3>
                <p>Cola de {selected}. Las acciones se aplican a este puesto.</p></div>
            </div>
            <dl className="skip-stats">
              <div><dt>{pending.nextCursor == null ? 'En cola' : 'Cargados'}</dt><dd>{panels.length}</dd></div>
              <div><dt>Salteados</dt><dd>{skipped}</dd></div>
              <div><dt>Pendientes</dt><dd>{panels.length - skipped}</dd></div>
            </dl>
          </section>

          {printing && <section className="skip-assignment">
            <h3>Impresión de Salteo · {selected}</h3>
            <p>Pendientes {printCount('PENDIENTE')} · En envío {printCount('ENVIANDO')} · Enviadas {printCount('ENVIADA')} · Con error {printCount('ERROR')}</p>
            {printing.canConfigure ? <div className="skip-tools-actions">
              <label>Impresora alternativa <select className="skip-sequence-filter" value={printerName} onChange={event => setPrinterName(event.target.value)}>
                <option value="">Elegí una impresora de Windows</option>
                {printing.name && !printing.printers.includes(printing.name) && <option value={printing.name} disabled>{printing.name} (no disponible o igual a la normal)</option>}
                {printing.printers.map(name => <option key={name}>{name}</option>)}
              </select></label>
              <button className="skip-button skip-blue" disabled={busy || !printing.printers.includes(printerName) || printerName === printing.name}
                onClick={() => void run(async () => {
                  await call(apiBaseUrl, password, 'printing', { station: selected, name: printerName });
                  await loadPrinting();
                })}>Guardar impresora</button>
            </div> : <p>Impresora guardada: {printing.name || 'Sin configurar'}. Configurala desde la PC de este puesto.</p>}
            {!printing.name && <p>Las etiquetas quedan pendientes hasta que el puesto tenga una impresora alternativa.</p>}
            <div className="skip-tools-actions">
              <button className="skip-button" disabled={busy} onClick={() => void run(loadPrinting)}>Actualizar cola</button>
              <button className="skip-button" disabled={busy || printCount('ERROR') === 0} onClick={() => void run(async () => {
                await call(apiBaseUrl, password, 'printing/retry', { station: selected });
                await loadPrinting();
              })}>Reintentar fallidas</button>
              <button className="skip-button" disabled={busy} onClick={() => setPrinting(null)}>Cerrar</button>
            </div>
          </section>}

          {assignment && <section className="skip-assignment">
            <h3>Paneles que procesa {selected}</h3>
            <p>La asignación se aplica a las órdenes siguientes al puntero del puesto.</p>
            <label><input type="checkbox" disabled={busy} checked={assignment.restricted}
              onChange={event => setAssignment({ ...assignment, restricted: event.target.checked })} /> Limitar a los tipos marcados</label>
            <div className="skip-assignment-grid">
              {panelTypes.map(panel => <label key={panel.bit}>
                <input type="checkbox" disabled={busy || !assignment.restricted}
                  checked={(assignment.mask & panel.bit) !== 0} onChange={event => setAssignment({
                    ...assignment, mask: event.target.checked ? assignment.mask | panel.bit : assignment.mask & ~panel.bit,
                  })} />
                <span><strong>{panel.code}</strong><small>{panel.label}</small></span>
              </label>)}
            </div>
            <div className="skip-tools-actions">
              <button className="skip-button skip-blue" disabled={busy || (assignment.restricted && assignment.mask === 0)}
                onClick={() => void saveAssignment()}>Guardar asignación</button>
              <button className="skip-button" disabled={busy} onClick={() => setAssignment(null)}>Cancelar</button>
            </div>
          </section>}

          <section className="skip-tools" aria-label="Filtros rápidos">
            <div><span className="skip-tools-label"><ListFilter size={17} /> Filtro rápido</span>
              <div className="skip-filter">
                {filterButton('all', `Todos (${panels.length})`)}
                {filterButton('pending', `Pendientes (${panels.length - skipped})`)}
                {filterButton('skipped', `Salteados (${skipped})`)}
                <select className="skip-sequence-filter" aria-label="Filtrar por secuencia"
                  value={groups.some(([key]) => key === filter) ? filter : ''} onChange={event => setFilter(event.target.value || 'all')}>
                  <option value="">Por secuencia…</option>
                  {groups.map(([key, rows]) => <option key={key} value={key}>
                    {rows[0].sequence} · {rows[0].productionDate}
                  </option>)}
                </select>
                <select className="skip-sequence-filter" aria-label="Filtrar por SD" value={sdFilter} disabled={busy}
                  onChange={event => { const sd = event.target.value; void run(() => load(selected, 0, sd, true)); }}>
                  <option value="">Todos los SD</option>
                  {sdFilter && !pending.sdOptions.includes(sdFilter) && <option value={sdFilter}>{sdFilter}</option>}
                  {pending.sdOptions.map(sd => <option key={sd} value={sd}>{sd}</option>)}
                </select>
              </div>
            </div>
            <div className="skip-tools-actions">
              {visibleGroups.slice(0, 2).map(rows => <button key={groupKey(rows[0])} className="skip-button skip-outline-orange"
                disabled={busy || rows.every(panel => panel.skipped || panel.started)}
                onClick={() => setAction({ mode: 0, anchor: rows[0], entireSequence: true })}>
                <ChevronsRight size={17} /> Saltear Sec. {rows[0].sequence}
              </button>)}
              <button className="skip-text" disabled={busy || eligible.length === 0} onClick={selectAll}>Seleccionar visibles</button>
            </div>
          </section>

          {notice && <p className="skip-notice" role="status">{notice}</p>}
          {error && !action && <p className="skip-error" role="alert">{error}</p>}

          {visibleGroups.map(rows => {
            const first = rows[0];
            const count = rows.filter(panel => panel.skipped).length;
            const fullSequenceMarked = markedSequences.some(panel => groupKey(panel) === groupKey(first));
            return <section className="skip-group" key={groupKey(first)}>
              <div className="skip-group-heading">
                <label className="skip-group-select" title="Marcar secuencia completa">
                  <input type="checkbox" aria-label={`Seleccionar secuencia completa ${first.sequence} del ${first.productionDate}`}
                    checked={fullSequenceMarked} disabled={busy}
                    onChange={event => {
                      setMarked([]);
                      setMarkedSequences(previous => event.target.checked ? [...previous, first] :
                        previous.filter(panel => groupKey(panel) !== groupKey(first)));
                    }} />
                  <span className="skip-sequence" data-skipped={count === rows.length}>Secuencia {first.sequence}</span>
                </label>
                <span>SD <strong>{[...new Set(rows.map(panel => panel.sd || '—'))].join(' / ')}</strong></span>
                <time>{first.productionDate}</time>
                <span className="skip-group-count" data-skipped={count > 0}>{count > 0 ? `${count} salteado(s)` : `${rows.length} en cola`}</span>
                <button className="skip-text skip-invert" disabled={busy} onClick={() =>
                  setAction({ mode: 2, anchor: first, entireSequence: true })}><ArrowLeftRight size={14} /> Invertir Sec. {first.sequence}</button>
              </div>
              <div className="skip-grid">
                {rows.map(panel => {
                  const front = ['F', 'FR'].includes(panel.position?.toUpperCase() ?? '');
                  const rear = ['R', 'RR'].includes(panel.position?.toUpperCase() ?? '');
                  const left = ['L', 'LH', 'IZQ'].includes(panel.hand?.toUpperCase() ?? '');
                  const right = ['R', 'RH', 'DER'].includes(panel.hand?.toUpperCase() ?? '');
                  const quadrant = (front || rear) && (left || right) ? (rear ? 2 : 0) + (right ? 1 : 0) : -1;
                  return <article key={panel.orderId} className="skip-card" data-skipped={panel.skipped} data-marked={fullSequenceMarked || marked.includes(panel.orderId)}>
                    <div className="skip-card-top">
                      <input type="checkbox" aria-label={`Marcar panel ${panel.reference}, orden ${panel.orderId}`}
                        disabled={busy || panel.started || markedSequences.length > 0} checked={fullSequenceMarked || marked.includes(panel.orderId)}
                        onChange={event => setMarked(previous => event.target.checked
                          ? [...previous, panel.orderId] : previous.filter(id => id !== panel.orderId))} />
                      <div><h4>{panel.position || '—'} / {panel.hand || '—'}</h4>
                      </div>
                      <span className="skip-badge">{panel.skipped ? 'Salteado' : panel.started ? 'En proceso' : 'Pendiente'}</span>
                      <div className="skip-map" aria-hidden="true">{[0, 1, 2, 3].map(index => <i key={index} data-current={index === quadrant} />)}</div>
                    </div>
                    <div className="skip-card-bottom"><strong className="skip-part-reference" title="Número de parte">{panel.reference}</strong>
                      <button className={`skip-button ${panel.skipped ? 'skip-orange' : ''}`} disabled={busy || panel.started}
                        onClick={() => setAction({ mode: panel.skipped ? 1 : 0, anchor: panel })}>
                        {panel.skipped ? 'Restaurar' : 'Saltear Panel'}
                      </button>
                    </div>
                  </article>;
                })}
              </div>
            </section>;
          })}
          {!visible.length && <p className="skip-notice">No hay paneles para este filtro.</p>}
          {pending.nextCursor != null && <button className="skip-button" disabled={busy}
            onClick={() => void run(() => load(selected, pending.nextCursor ?? 0))}>Cargar más paneles</button>}
        </>}
        {error && !pending && <p className="skip-error" role="alert">{error}</p>}
      </div>
      {pending && <footer className="skip-footer" data-confirming={action !== null}>
        {action ? <>
          <div className="skip-confirm-summary">
            <p><strong>{actionText[action.mode]}</strong> {action.ids ? (action.entireSequence ? `${action.ids.length} secuencias completas` : `${action.ids.length} panel(es) marcados`) : action.entireSequence
              ? `la secuencia completa ${action.anchor?.sequence} del ${action.anchor?.productionDate}`
              : `el panel ${action.anchor?.reference} de la secuencia ${action.anchor?.sequence}`} en {selected}.</p>
            {error && <p className="skip-error" role="alert">{error}</p>}
          </div>
          <div>
            <button ref={confirmButton} className="skip-button skip-orange" disabled={busy} onClick={() => void save()}>Confirmar {actionText[action.mode].toLowerCase()}</button>
            <button className="skip-button" disabled={busy} onClick={() => setAction(null)}>Cancelar</button>
          </div>
        </> : <>
        <div>{markedSequences.length > 0 ? <strong>{markedSequences.length} {markedSequences.length === 1 ? 'secuencia completa seleccionada' : 'secuencias completas seleccionadas'}</strong> :
          <><span className="skip-selection-count">{marked.length}</span> <strong>paneles seleccionados</strong></>}
          <button className="skip-text" disabled={!marked.length && !markedSequences.length} onClick={() => {
            setMarked([]); setMarkedSequences([]);
          }}>Desmarcar selección</button></div>
        <div>
          <button className="skip-button skip-orange" disabled={busy || (!markedSequences.length && !markedPanels.some(panel => !panel.skipped))}
            onClick={() => setAction(markedSequences.length ? { mode: 0, ids: markedSequences.map(panel => panel.orderId), entireSequence: true } :
              { mode: 0, ids: markedPanels.filter(panel => !panel.skipped).map(panel => panel.orderId) })}>
            <ChevronsRight size={17} /> {markedSequences.length ? 'Saltear secuencias' : 'Saltear marcados'}
          </button>
          <button className="skip-button" disabled={busy || (!markedSequences.length && !markedPanels.some(panel => panel.skipped))}
            onClick={() => setAction(markedSequences.length ? { mode: 1, ids: markedSequences.map(panel => panel.orderId), entireSequence: true } :
              { mode: 1, ids: markedPanels.filter(panel => panel.skipped).map(panel => panel.orderId) })}>
            <RotateCcw size={16} /> {markedSequences.length ? 'Restaurar secuencias' : 'Restaurar marcados'}
          </button>
        </div>
        </>}
      </footer>}
    </main>
  );
}
