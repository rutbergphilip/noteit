/** Reminder identity (native ReminderIdentity): the same id on every device, so claims line up. */
import { sha256HexSync } from './sha256.js';
import { type LocalDateTime, localDateTimeToken, taskDisplayText } from './tokens.js';

/** A version 8 UUID from SHA-256 of "reminder\0<NOTE ID>\0<token time>\0<line display text>". */
export function reminderId(noteID: string, at: LocalDateTime, lineText: string): string {
  const input = `reminder\u0000${noteID.toUpperCase()}\u0000${localDateTimeToken(at)}\u0000${taskDisplayText(lineText)}`;
  const hex = sha256HexSync(new TextEncoder().encode(input)).slice(0, 32).split('');
  hex[12] = '8';
  hex[16] = ((parseInt(hex[16]!, 16) & 0x3) | 0x8).toString(16);
  const h = hex.join('').toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
