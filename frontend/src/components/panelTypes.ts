const frontNames = ['F', 'FR', 'DELANTERA', 'DELANTERO'];
const rearNames = ['R', 'RR', 'TRASERA', 'TRASERO'];
const leftNames = ['L', 'LH', 'IZQ', 'IZQUIERDA', 'IZQUIERDO'];
const rightNames = ['R', 'RH', 'DER', 'DERECHA', 'DERECHO'];

export const panelTypes = [
  { bit: 1, code: 'FR LH', position: 'FR', hand: 'LH', label: 'Delantero izquierdo' },
  { bit: 2, code: 'FR RH', position: 'FR', hand: 'RH', label: 'Delantero derecho' },
  { bit: 4, code: 'RR LH', position: 'RR', hand: 'LH', label: 'Trasero izquierdo' },
  { bit: 8, code: 'RR RH', position: 'RR', hand: 'RH', label: 'Trasero derecho' },
] as const;

export function getPanelType(position?: string, hand?: string) {
  const positionName = position?.trim().toUpperCase() ?? '';
  const handName = hand?.trim().toUpperCase() ?? '';
  const positionCode = frontNames.includes(positionName) ? 'FR' : rearNames.includes(positionName) ? 'RR' : null;
  const handCode = leftNames.includes(handName) ? 'LH' : rightNames.includes(handName) ? 'RH' : null;
  return panelTypes.find(panel => panel.position === positionCode && panel.hand === handCode);
}
