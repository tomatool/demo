// formatPrice renders cents as the shop shows prices: "2.50 EUR".
export function formatPrice(cents, currency = 'EUR') {
  const value = Number(cents);
  return `${Math.floor(value / 100)}.${String(value % 100).padStart(2, '0')} ${currency}`;
}
