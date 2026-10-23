/** Case-, diacritic- and width-insensitive folding on NFC text (= Swift TextFold.fold). */
export function searchFold(s: string): string {
  return s.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().normalize('NFC');
}

/** Every whitespace-separated term of the query must occur in the haystack. */
export function matchesSearch(haystack: string, query: string): boolean {
  const terms = searchFold(query).split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const folded = searchFold(haystack);
  return terms.every((t) => folded.includes(t));
}
