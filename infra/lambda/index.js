const crypto = require('crypto');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

const ssm = new SSMClient({ region: process.env.AWS_REGION || 'eu-west-1' });

// Cache the private key after first fetch
let cachedPrivateKey = null;
let privateKeyFetchTime = 0;
const PRIVATE_KEY_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

/**
 * Retrieve the CloudFront private key from SSM Parameter Store.
 * Caches it in memory for 5 minutes to reduce SSM calls.
 */
async function getPrivateKey() {
  const now = Date.now();
  if (cachedPrivateKey && (now - privateKeyFetchTime) < PRIVATE_KEY_CACHE_TTL_MS) {
    return cachedPrivateKey;
  }

  const command = new GetParameterCommand({
    Name: process.env.PRIVATE_KEY_SSM_PATH,
    WithDecryption: true,
  });

  const response = await ssm.send(command);
  cachedPrivateKey = response.Parameter.Value;
  privateKeyFetchTime = now;
  return cachedPrivateKey;
}

/**
 * Generate a signed CloudFront URL using a canned policy.
 *
 * @param {string} resourceUrl - The CloudFront URL of the resource
 * @param {string} privateKeyPem - The RSA private key in PEM format
 * @param {string} keyPairId - The CloudFront key pair ID
 * @param {number} expiresInSeconds - Seconds from now until the URL expires
 * @returns {string} Signed URL
 */
function generateSignedUrl(resourceUrl, privateKeyPem, keyPairId, expiresInSeconds) {
  const expiryTime = Math.floor(Date.now() / 1000) + expiresInSeconds;

  // Create the canned policy
  const policy = JSON.stringify({
    Statement: [
      {
        Resource: resourceUrl,
        Condition: {
          DateLessThan: {
            'AWS:EpochTime': expiryTime,
          },
        },
      },
    ],
  });

  // Sign the policy with the private key
  const signer = crypto.createSign('RSA-SHA1');
  signer.update(policy);
  const signature = signer.sign(privateKeyPem, 'base64');

  // URL-encode the signature
  const encodedSignature = encodeURIComponent(signature);

  // Append query parameters
  const separator = resourceUrl.includes('?') ? '&' : '?';
  return `${resourceUrl}${separator}Expires=${expiryTime}&Signature=${encodedSignature}&Key-Pair-Id=${keyPairId}`;
}

function json(statusCode, body, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type,X-Live-Admin-Token',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
      'Cache-Control': 'no-store',
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  };
}

async function handleLiveSession(event) {
  if (event.requestContext?.httpMethod === 'OPTIONS' || event.httpMethod === 'OPTIONS') {
    return json(200, { ok: true });
  }

  const expectedToken = process.env.LIVE_ADMIN_TOKEN;
  const suppliedToken =
    event.headers?.['x-live-admin-token'] ||
    event.headers?.['X-Live-Admin-Token'] ||
    (() => {
      try {
        return event.body ? JSON.parse(event.body).adminToken : undefined;
      } catch {
        return undefined;
      }
    })();

  if (!expectedToken) {
    return json(500, { error: 'LIVE_ADMIN_TOKEN is not configured' });
  }

  if (!suppliedToken || suppliedToken !== expectedToken) {
    return json(401, { error: 'Invalid live admin token' });
  }

  const streamKey = process.env.LIVE_STREAM_KEY;
  const ingestEndpoint = process.env.LIVE_INGEST_ENDPOINT;
  const playbackUrl = process.env.LIVE_PLAYBACK_URL;

  if (!streamKey || !ingestEndpoint || !playbackUrl) {
    return json(500, { error: 'Live streaming environment variables are incomplete' });
  }

  return json(200, {
    ingestEndpoint,
    streamKey,
    playbackUrl,
    streamUrl: `rtmps://${ingestEndpoint}:443/app/`,
    channelType: 'STANDARD',
    latencyMode: 'LOW',
  });
}

/**
 * Lambda handler for GET /audio/{trackId}
 *
 * Query parameters:
 *   - type: "preview" (20s), "rent" (24h), or "buy" (365d). Default: "preview"
 *
 * Returns JSON with the signed URL.
 */
exports.handler = async (event) => {
  try {
    const resourcePath = event.resource || event.requestContext?.resourcePath || '';
    const path = event.path || '';

    if (resourcePath === '/live/session' || path.endsWith('/live/session')) {
      return await handleLiveSession(event);
    }

    const trackId = event.pathParameters?.trackId;
    if (!trackId) {
      return json(400, { error: 'Missing trackId parameter' });
    }

    // Determine the access type and corresponding duration
    const accessType = event.queryStringParameters?.type || 'preview';
    let expiresInSeconds;

    switch (accessType) {
      case 'preview':
        expiresInSeconds = parseInt(process.env.PREVIEW_DURATION_SECONDS || '20', 10);
        break;
      case 'rent':
        expiresInSeconds = parseInt(process.env.RENT_DURATION_HOURS || '24', 10) * 3600;
        break;
      case 'buy':
        expiresInSeconds = parseInt(process.env.BUY_DURATION_DAYS || '365', 10) * 86400;
        break;
      default:
        return json(400, { error: `Invalid type: ${accessType}. Use "preview", "rent", or "buy".` });
    }

    // Map trackId to S3 key (clean lowercase filenames, no spaces/dates)
    const trackManifest = {
      'track-1': 'tracks/session-dobrichlapci-track-1.wav',
      'track-2': 'tracks/session-dobrichlapci-track-2.wav',
      'track-3': 'tracks/session-dobrichlapci-track-3.wav',
      'track-4': 'tracks/session-dobrichlapci-track-4.wav',
      'track-5': 'tracks/session-dobrichlapci-track-5.wav',
      'track-6': 'tracks/session-dobrichlapci-track-6.wav',
      'track-7': 'tracks/speedstop.mp3',
      'track-8': 'tracks/okupe.mp3',
      'hero-video': 'tracks/hero-bg-video.mp4',
    };

    const s3Key = trackManifest[trackId];
    if (!s3Key) {
      return json(404, { error: `Track not found: ${trackId}` });
    }

    const cloudfrontDomain = process.env.CLOUDFRONT_DOMAIN;
    const keyPairId = process.env.CLOUDFRONT_KEY_PAIR_ID;

    if (!cloudfrontDomain || !keyPairId) {
      throw new Error('Missing CLOUDFRONT_DOMAIN or CLOUDFRONT_KEY_PAIR_ID environment variables');
    }

    // Build the CloudFront resource URL
    const resourceUrl = `https://${cloudfrontDomain}/${encodeURIComponent(s3Key)}`;

    // Get the private key and generate the signed URL
    const privateKeyPem = await getPrivateKey();
    const signedUrl = generateSignedUrl(resourceUrl, privateKeyPem, keyPairId, expiresInSeconds);

    return json(200, {
      trackId,
      accessType,
      url: signedUrl,
      expiresInSeconds,
    });
  } catch (error) {
    console.error('Error generating signed URL:', error);
    return json(500, { error: 'Internal server error' });
  }
};