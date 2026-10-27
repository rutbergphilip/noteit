/**
 * Where a run of list items breaks into a new list, as the Mac's Markdown export writes it (Swift `ListRuns`): a
 * top-level item of a different kind (bullet, ordered, task) than the run's last top-level item starts a new list
 * after a blank line. That blank line separates the two lists; it is never an empty paragraph.
 */
export function listRuns(): (node: { type: string; attrs?: { kind?: string; level?: number } } | undefined) => boolean {
  let topKind: string | undefined;
  return (node) => {
    if (node?.type !== 'listItem') {
      topKind = undefined;
      return false;
    }
    if ((node.attrs?.level ?? 0) !== 0) return false;
    const kind = node.attrs?.kind ?? 'bullet';
    const starts = topKind !== undefined && topKind !== kind;
    topKind = kind;
    return starts;
  };
}
