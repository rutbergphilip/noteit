import { defineEventHandler, type EventHandler } from 'h3';
import { serverContext } from '../../lib/context';
import { createS3Handler } from '../../lib/s3';

let handler: Promise<EventHandler> | undefined;

export default defineEventHandler(async (event) => {
  handler ??= serverContext().then(createS3Handler);
  return (await handler)(event);
});
