/**
 * The bucket CORS rules direct mode needs (spec §6.4), per provider, for the connect wizard's help. The same examples
 * are in docs/self-hosting.md; test/app/corsExamples.test.ts checks their shape.
 */

export const CORS_METHODS = ['GET', 'PUT', 'HEAD', 'DELETE'];
export const CORS_HEADERS = ['authorization', 'content-type', 'if-match', 'if-none-match', 'x-amz-content-sha256', 'x-amz-date'];

export function awsCors(origin: string): string {
  return JSON.stringify(
    { CORSRules: [{ AllowedOrigins: [origin], AllowedMethods: CORS_METHODS, AllowedHeaders: CORS_HEADERS, ExposeHeaders: ['ETag'], MaxAgeSeconds: 3600 }] },
    null,
    2,
  );
}

export function r2Cors(origin: string): string {
  return JSON.stringify([{ AllowedOrigins: [origin], AllowedMethods: CORS_METHODS, AllowedHeaders: CORS_HEADERS, ExposeHeaders: ['ETag'], MaxAgeSeconds: 3600 }], null, 2);
}

export function b2CorsRules(origin: string): string {
  return JSON.stringify(
    [
      {
        corsRuleName: 'noteit',
        allowedOrigins: [origin],
        allowedOperations: ['s3_get', 's3_head', 's3_put', 's3_delete'],
        allowedHeaders: CORS_HEADERS,
        exposeHeaders: ['ETag'],
        maxAgeSeconds: 3600,
      },
    ],
    null,
    2,
  );
}

export function corsExamples(origin: string, bucket = 'my-notes'): { id: string; label: string; intro: string; code: string }[] {
  return [
    { id: 'aws', label: 'AWS S3', intro: `Save as cors.json, then: aws s3api put-bucket-cors --bucket ${bucket} --cors-configuration file://cors.json`, code: awsCors(origin) },
    { id: 'r2', label: 'Cloudflare R2', intro: 'Bucket › Settings › CORS Policy in the dashboard, or the AWS command with --endpoint-url https://<account-id>.r2.cloudflarestorage.com.', code: r2Cors(origin) },
    { id: 'minio', label: 'MinIO', intro: 'CORS is server-wide in MinIO: set this and restart. Its CORS handler already allows the methods and exposes ETag.', code: `MINIO_API_CORS_ALLOW_ORIGIN=${origin}` },
    { id: 'b2', label: 'Backblaze B2', intro: `With the b2 CLI (v4): b2 bucket update --cors-rules '<rules>' ${bucket} allPrivate`, code: b2CorsRules(origin) },
  ];
}
