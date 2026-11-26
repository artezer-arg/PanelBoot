import { useEffect, useState } from 'react';
import { ChevronDown, FlaskConical, ListOrdered, Network, Plus, Save, SlidersHorizontal } from 'lucide-react';
import './PlcRecipeConfig.css';

type Rule = { pattern: string; matchMode: number; segmentIndex: number; description?: string; secondHandshakeValue?: number | null; cunaQr?: string | null; recipeValue?: number | null };
type Settings = {
  enabled: boolean; ipAddress: string; port: number; rack: number; slot: number;
  pollingIntervalMs: number; timeoutMs: number; dataBlock: number; recipeOffset: number;
  confirmationOffset: number; confirmationBit: number; stateOffset: number; modelOffset: number;
  enableRecipeHandshake: boolean; handshakeReqValue: number; handshakeAckValue: number;
  handshakeIdleValue: number; enableDualHandshake: boolean; sendConfirmation: boolean;
  confirmationValue: boolean; delimiter: string; requireConfiguredRule: boolean;
  defaultSegmentIndex: number | null; minimumRecipe: number; maximumRecipe: number; rules: Rule[];
};
type Preview = { segments: string[]; position?: number; recipe?: number; error?: string };

type NumberKey = { [K in keyof Settings]: Settings[K] extends number ? K : never }[keyof Settings];
type ToggleKey = { [K in keyof Settings]: Settings[K] extends boolean ? K : never }[keyof Settings];

async function call<T>(api: string, password: string, path: string, method = 'GET', body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${api}/api/plc-recipe/${path}`, {
    method, headers: { 'Content-Type': 'application/json', 'X-Door-Supervisor': password },
    body: body === undefined ? undefined : JSON.stringify(body), signal,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.message || data.title || (response.status === 401
    ? 'Se requiere la contraseña de supervisor.' : 'Falló la operación PLC.'));
  return data as T;
}

export function PlcRecipeConfig({ api, password }: { api: string; password: string }) {
  const [draft, setDraft] = useState<Settings | null>(null);
  const [saved, setSaved] = useState<Settings | null>(null);
  const [qr, setQr] = useState('');
  const [model, setModel] = useState('');
  const [manual, setManual] = useState('');
  const [confirmBit, setConfirmBit] = useState(false);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [message, setMessage] = useState('');
  const [diagnosticMessage, setDiagnosticMessage] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const abort = new AbortController();
    call<Settings>(api, password, 'settings', 'GET', undefined, abort.signal)
      .then(value => { setDraft(value); setSaved(value); })
      .catch(error => { if (!abort.signal.aborted) setMessage(error.message); });
    return () => abort.abort();
  }, [api, password]);

  useEffect(() => {
    if (!draft || !qr.trim() || !model.trim()) return;
    const abort = new AbortController();
    const timer = window.setTimeout(() => {
      call<Preview>(api, password, 'preview', 'POST', { options: draft, model, qr }, abort.signal)
        .then(setPreview)
        .catch(error => { if (!abort.signal.aborted) setPreview({ segments: [], error: error.message }); });
    }, 250);
    return () => { clearTimeout(timer); abort.abort(); };
  }, [api, password, draft, model, qr]);

  function update<K extends keyof Settings>(key: K, value: Settings[K]) {
    setDraft(previous => previous && ({ ...previous, [key]: value }));
  }

  function updateRule(index: number, changes: Partial<Rule>) {
    if (!draft) return;
    update('rules', draft.rules.map((rule, position) => position === index ? { ...rule, ...changes } : rule));
  }

  async function run(action: () => Promise<string>, report = setDiagnosticMessage) {
    setBusy(true);
    try { report(await action()); }
    catch (error) { report(error instanceof Error ? error.message : 'Falló la operación PLC.'); }
    finally { setBusy(false); }
  }

  async function send(useHandshake: boolean) {
    const recipe = manual.trim() ? Number(manual) : null;
    if (recipe !== null && (!Number.isInteger(recipe) || recipe < -32768 || recipe > 32767)) {
      setDiagnosticMessage('Ingresá un entero entre -32768 y 32767.');
      return;
    }
    if (!window.confirm('¿Enviar la receta de prueba al PLC conectado?')) return;
    await run(async () => {
      const result = await call<{ transfer: { recipe: number; verifiedRecipe: number; state?: number; confirmation?: boolean } }>(
        api, password, 'send', 'POST', { recipe, qr, model, useHandshake, sendConfirmation: confirmBit });
      const { transfer } = result;
      return `Receta ${transfer.recipe} confirmada · leído ${transfer.verifiedRecipe}`
        + (transfer.state == null ? '' : ` · estado ${transfer.state}`)
        + (transfer.confirmation == null ? '' : ` · bit ${Number(transfer.confirmation)}`);
    });
  }

  if (!draft) return <section className="plc-panel"><h3>PLC Siemens S7-1500</h3><p role="status">{message || 'Cargando configuración…'}</p></section>;

  const numberField = (key: NumberKey, label: string) => (
    <label className="plc-field">{label}<input className="form-input" type="number" value={draft[key]}
      onChange={event => update(key, Number(event.target.value))} /></label>
  );
  const toggle = (key: ToggleKey, label: string) => (
    <label className="plc-check"><input type="checkbox" checked={draft[key]}
      onChange={event => update(key, event.target.checked)} />{label}</label>
  );
  const dirty = draft !== saved;

  return (
    <section className="plc-panel" aria-label="Configuración del PLC">
      <header className="plc-header">
        <div className="plc-heading">
          <div className="plc-icon"><Network size={22} aria-hidden="true" /></div>
          <div>
            <h3>PLC Siemens S7-1500</h3>
            <span className="plc-subtitle">Recetas de cámara por SD o modelo</span>
          </div>
        </div>
        <div className="plc-actions">
          <span className="plc-status" data-enabled={saved?.enabled === true}>{saved?.enabled ? 'Habilitado' : 'Deshabilitado'}</span>
          {dirty && <small>Cambios sin guardar</small>}
          <button type="button" className="btn btn-primary" disabled={busy || !dirty} onClick={() => void run(async () => {
            const value = await call<Settings>(api, password, 'settings', 'PUT', draft);
            setDraft(value); setSaved(value);
            return value.enabled ? 'Configuración guardada. PLC habilitado.' : 'Configuración guardada. PLC deshabilitado.';
          }, setMessage)}><Save size={16} aria-hidden="true" /> Guardar cambios</button>
        </div>
      </header>

      <div className="plc-connection">
        {toggle('enabled', 'Habilitar comunicación con el PLC')}
        <label className="plc-field">Dirección IP<input className="form-input" value={draft.ipAddress}
          onChange={event => update('ipAddress', event.target.value)} /></label>
        {numberField('port', 'Puerto TCP')}
      </div>
      {message && <p className="plc-feedback" role="status">{message}</p>}

      <div className="plc-main">
        <section className="plc-card" aria-labelledby="plc-rules-title">
          <div className="plc-card-heading">
            <h4 id="plc-rules-title"><ListOrdered size={19} aria-hidden="true" /> Reglas por SD o modelo</h4>
            <button type="button" className="btn btn-secondary" onClick={() =>
              update('rules', [...draft.rules, { pattern: '', matchMode: 0, segmentIndex: 1 }])}>
              <Plus size={16} aria-hidden="true" /> Agregar regla
            </button>
          </div>
          <p className="plc-hint">Asigná un valor a un QR de cuna para cada modelo, o elegí una posición si el QR incluye los valores.</p>
          <ol className="plc-rules">
            {draft.rules.map((rule, index) => (
              <li key={index}>
                <fieldset className="plc-rule">
                  <legend>Regla {index + 1}</legend>
                  <div className="plc-rule-fields">
                    <label className="plc-field">SD o modelo<input className="form-input" placeholder="D3L FR RH"
                      value={rule.pattern} onChange={event => updateRule(index, { pattern: event.target.value })} /></label>
                    <label className="plc-field">Coincidencia<select className="form-input" value={rule.matchMode}
                      onChange={event => updateRule(index, { matchMode: Number(event.target.value) })}>
                      <option value={0}>Exacta</option><option value={1}>Empieza con</option><option value={2}>Contiene</option>
                    </select></label>
                    <label className="plc-field">Origen del valor<select className="form-input" value={rule.cunaQr == null ? 'position' : 'assigned'}
                      onChange={event => updateRule(index, event.target.value === 'assigned'
                        ? { cunaQr: '', recipeValue: null } : { cunaQr: null, recipeValue: null })}>
                      <option value="position">Posición del QR</option><option value="assigned">Valor asignado</option>
                    </select></label>
                  </div>
                  <div className="plc-rule-extra">
                    {rule.cunaQr == null ? <label className="plc-field">Posición del QR<input className="form-input" type="number" min="1"
                      value={rule.segmentIndex} onChange={event => updateRule(index, { segmentIndex: Number(event.target.value) })} /></label> : <>
                      <label className="plc-field">QR exacto de la cuna<input className="form-input" placeholder="CUNA-01"
                        value={rule.cunaQr} onChange={event => updateRule(index, { cunaQr: event.target.value })} /></label>
                      <label className="plc-field">Valor a enviar al PLC<input className="form-input" type="number" min={draft.minimumRecipe} max={draft.maximumRecipe}
                        value={rule.recipeValue ?? ''} onChange={event => updateRule(index, {
                          recipeValue: event.target.value === '' ? null : Number(event.target.value),
                        })} /></label>
                    </>}
                  </div>
                  <div className="plc-rule-extra">
                    <label className="plc-field">Descripción opcional<input className="form-input" value={rule.description ?? ''}
                      onChange={event => updateRule(index, { description: event.target.value })} /></label>
                    {(draft.enableDualHandshake || rule.secondHandshakeValue != null) &&
                      <label className="plc-field">Valor del segundo handshake<input className="form-input" type="number"
                        value={rule.secondHandshakeValue ?? ''} onChange={event => updateRule(index, {
                          secondHandshakeValue: event.target.value ? Number(event.target.value) : null,
                        })} /></label>}
                    <button type="button" className="btn btn-secondary plc-remove" aria-label={`Eliminar regla ${index + 1}`}
                      onClick={() => update('rules', draft.rules.filter((_, position) => position !== index))}>Eliminar</button>
                  </div>
                </fieldset>
              </li>
            ))}
          </ol>
          {draft.rules.length === 0 && <p className="plc-empty">Todavía no hay reglas. Agregá un SD o modelo para indicar qué número extraer.</p>}
          <div className="plc-rule-options">
            <label className="plc-field">Separador del QR<input className="form-input" value={draft.delimiter}
              onChange={event => update('delimiter', event.target.value)} /></label>
            <label className="plc-field">Posición por defecto<input className="form-input" type="number" min="1"
              disabled={draft.requireConfiguredRule} value={draft.defaultSegmentIndex ?? ''}
              onChange={event => update('defaultSegmentIndex', event.target.value ? Number(event.target.value) : null)} /></label>
            {toggle('requireConfiguredRule', 'Exigir una regla para el modelo')}
          </div>
        </section>

        <section className="plc-card plc-preview" aria-labelledby="plc-preview-title">
          <h4 id="plc-preview-title"><FlaskConical size={19} aria-hidden="true" /> Probar extracción</h4>
          <p className="plc-hint">Simulá la lectura del QR sin enviar datos al PLC.</p>
          <label className="plc-field">SD o modelo de prueba<input className="form-input" placeholder="D3L FR RH"
            value={model} onChange={event => { setModel(event.target.value); setPreview(null); }} /></label>
          <label className="plc-field">QR de la cuna<input className="form-input" placeholder="CUNA-01 o 20-14-12"
            value={qr} onChange={event => { setQr(event.target.value); setPreview(null); }} /></label>
          <div className="plc-preview-result" role="status">
            {model.trim() && qr.trim() && preview ? <>
              <div className="plc-segments">
                {preview.segments.map((segment, index) => (
                  <span key={index} data-selected={preview.position === index + 1}><small>Pos. {index + 1}</small><strong>{segment || '—'}</strong></span>
                ))}
              </div>
              {preview.error ? <strong className="plc-error">{preview.error}</strong> : <strong>Valor para el PLC · {preview.recipe}</strong>}
            </> : <span>{model.trim() && qr.trim() ? 'Calculando receta…' : 'Completá ambos campos para ver la receta.'}</span>}
          </div>
        </section>
      </div>

      <details className="plc-details">
        <summary><SlidersHorizontal size={19} aria-hidden="true" /> Ajustes avanzados <ChevronDown size={17} className="plc-chevron" aria-hidden="true" /></summary>
        <div className="plc-details-body">
          <section><h5>Conexión y tiempos</h5><div className="plc-fields">
            {numberField('rack', 'Rack')}{numberField('slot', 'Ranura')}
            {numberField('pollingIntervalMs', 'Intervalo de lectura (ms)')}{numberField('timeoutMs', 'Tiempo máximo (ms)')}
          </div></section>
          <section><h5>Direcciones del bloque de datos</h5><div className="plc-fields">
            {numberField('dataBlock', 'Número de DB')}{numberField('recipeOffset', 'Offset de receta (INT)')}
            {numberField('stateOffset', 'Offset de estado (INT)')}{numberField('modelOffset', 'Offset del modelo (INT)')}
            {numberField('confirmationOffset', 'Byte de confirmación')}{numberField('confirmationBit', 'Bit de confirmación')}
          </div></section>
          <section><h5>Modo de envío</h5><div className="plc-fields">
            {toggle('enableRecipeHandshake', 'Usar handshake')}{toggle('enableDualHandshake', 'Permitir segundo handshake por regla')}
            {toggle('sendConfirmation', 'Enviar bit de confirmación')}{toggle('confirmationValue', 'Enviar 1 en el bit de confirmación')}
            {numberField('handshakeReqValue', 'Solicitud (REQ)')}{numberField('handshakeAckValue', 'Confirmación (ACK)')}
            {numberField('handshakeIdleValue', 'Reposo (IDLE)')}
          </div></section>
          <section><h5>Rango de recetas</h5><div className="plc-fields">
            {numberField('minimumRecipe', 'Receta mínima')}{numberField('maximumRecipe', 'Receta máxima')}
          </div></section>
        </div>
      </details>

      <details className="plc-details">
        <summary><Network size={19} aria-hidden="true" /> Diagnóstico del PLC <ChevronDown size={17} className="plc-chevron" aria-hidden="true" /></summary>
        <div className="plc-details-body plc-diagnostics">
          <section>
            <h5>Conexión y lectura</h5>
            <p className="plc-hint">{saved?.enabled ? `Destino guardado · ${saved.ipAddress}:${saved.port}` : 'Habilitá el PLC y guardá los cambios para usar el diagnóstico.'}</p>
            <div className="plc-actions">
              <button type="button" className="btn btn-secondary" disabled={busy || !saved?.enabled} onClick={() => void run(async () => {
                const data = await call<{ latencyMs: number }>(api, password, 'tcp', 'POST');
                return `${saved?.ipAddress}:${saved?.port} respondió en ${data.latencyMs.toFixed(1)} ms.`;
              })}>Probar conexión TCP</button>
              <button type="button" className="btn btn-secondary" disabled={busy || !saved?.enabled} onClick={() => void run(async () => {
                const data = await call<{ state: number; model: number }>(api, password, 'status', 'POST');
                const state = data.state === saved?.handshakeReqValue ? 'REQ' : data.state === saved?.handshakeAckValue ? 'ACK' : data.state === saved?.handshakeIdleValue ? 'IDLE' : '';
                return `Estado ${data.state} ${state} · Modelo PLC ${data.model}`;
              })}>Leer estado y modelo</button>
            </div>
          </section>
          <section className="plc-write-test">
            <h5>Escritura de prueba</h5>
            <p className="plc-hint">Envía una receta al PLC con la configuración guardada. Si dejás vacío el valor manual, usa el QR y el modelo del probador.</p>
            <label className="plc-field">Receta manual opcional<input className="form-input" type="number" value={manual}
              onChange={event => setManual(event.target.value)} /></label>
            <label className="plc-check"><input type="checkbox" checked={confirmBit}
              onChange={event => setConfirmBit(event.target.checked)} /> Escribir también el bit de confirmación</label>
            <div className="plc-actions">
              <button type="button" className="btn btn-secondary" disabled={busy || !saved?.enabled} onClick={() => void send(false)}>Enviar directo</button>
              <button type="button" className="btn btn-secondary" disabled={busy || !saved?.enabled} onClick={() => void send(true)}>Enviar con handshake</button>
            </div>
          </section>
        </div>
        {diagnosticMessage && <p className="plc-feedback plc-diagnostic-feedback" role="status">{diagnosticMessage}</p>}
      </details>
    </section>
  );
}
