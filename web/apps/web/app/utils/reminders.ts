/**
 * Reminder notifications (native ReminderScheduler + ReminderClaims): while NoteIt is open in a tab, a reminder
 * whose time comes is claimed in the sync store first, so only one device rings; the device in use claims at
 * once, an idle one waits 20 s. Without notification permission the reminder shows as a notice in the app.
 */
import { localToDate } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

const CHECK_MS = 30_000;
const IDLE_DELAY_MS = 20_000;
const CATCH_UP_MS = 24 * 3600_000;
const SWEEP_MS = 24 * 3600_000;

let timer: ReturnType<typeof setInterval> | undefined;
const delivered = new Set<string>();

function store<T>(key: string, fallback: T): T {
  try {
    const v = localStorage.getItem(key);
    return v ? (JSON.parse(v) as T) : fallback;
  } catch {
    return fallback;
  }
}
function save(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // private mode: reminders still ring while the tab stays open
  }
}

export const notificationsSupported = () => typeof Notification !== 'undefined';

export async function askNotificationPermission(): Promise<NotificationPermission | 'unsupported'> {
  if (!notificationsSupported()) return 'unsupported';
  return Notification.permission === 'default' ? Notification.requestPermission() : Notification.permission;
}

export function startReminders(): void {
  stopReminders();
  void check();
  timer = setInterval(() => void check(), CHECK_MS);
}

export function stopReminders(): void {
  if (timer) clearInterval(timer);
  timer = undefined;
}

async function check(): Promise<void> {
  const { state, client, openNote, toast } = useNoteit();
  if (state.phase !== 'ready' || !state.session) return;
  const key = `noteit-reminders-${state.session.user.id}`;
  const now = Date.now();
  // Only reminders whose time came since the last check (at most a day back) ring, never a backlog on first run.
  const last = store<number | undefined>(`${key}-last`, undefined);
  const since = Math.max(last ?? now, now - CATCH_UP_MS);
  save(`${key}-last`, now);
  const due = (await client().liveReminders()).filter((r) => {
    const at = localToDate(r.at).getTime();
    return at > since && at <= now && !delivered.has(r.id);
  });
  for (const r of due) {
    delivered.add(r.id);
    void (async () => {
      if (document.visibilityState !== 'visible' || !document.hasFocus()) await new Promise((res) => setTimeout(res, IDLE_DELAY_MS));
      if ((await client().claimReminder(r.id, localToDate(r.at).getTime())) === 'alreadyClaimed') return;
      const body = r.noteTitle && r.noteTitle !== r.text ? r.noteTitle : undefined;
      if (notificationsSupported() && Notification.permission === 'granted') {
        const n = new Notification(r.text || 'Reminder', { ...(body ? { body } : {}), tag: r.id });
        n.onclick = () => {
          window.focus();
          openNote(r.noteId);
          n.close();
        };
      } else {
        toast(`Reminder: ${r.text || r.noteTitle}`, 'info', { label: 'Open', run: () => openNote(r.noteId) });
      }
    })();
  }
  if (now - store<number>(`${key}-sweep`, 0) > SWEEP_MS) {
    save(`${key}-sweep`, now);
    void client().sweepReminderClaims();
  }
}
