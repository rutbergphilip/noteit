import { defineEventHandler, type EventHandler } from 'h3';
import { createApiHandler } from '../../lib/api';
import { serverContext } from '../../lib/context';

let handler: Promise<EventHandler> | undefined;

export default defineEventHandler(async (event) => {
  handler ??= serverContext().then(createApiHandler);
  return (await handler)(event);
});
