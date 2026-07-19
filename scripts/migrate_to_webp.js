/**
 * migrate_to_webp.js
 *
 * Converts all JPG/PNG files in Firebase Storage to WebP and updates every
 * Firestore reference pointing to the old URL. Each file is processed
 * atomically: upload WebP → patch Firestore → delete original.
 *
 * ── Prerequisites ─────────────────────────────────────────────────────────────
 *   cd scripts
 *   npm install
 *
 *   Place service-account.json next to this file:
 *   Firebase Console → Project Settings → Service accounts →
 *   Generate new private key  (download JSON, rename to service-account.json)
 *
 * ── Usage ─────────────────────────────────────────────────────────────────────
 *   node migrate_to_webp.js                         # dry-run (no changes)
 *   node migrate_to_webp.js --execute               # migrate all images
 *   node migrate_to_webp.js --execute --prefix=avatars/   # one folder only
 */

'use strict';
const admin = require('firebase-admin');
const sharp = require('sharp');
const { v4: uuidv4 } = require('uuid');
const path = require('path');
const fs = require('fs');

// ── Config ────────────────────────────────────────────────────────────────────
const WEBP_QUALITY = 87;   // lossy quality for JPEG sources
const IMAGE_EXTS = new Set(['.jpg', '.jpeg', '.png']);
const CONCURRENT = 5;       // files processed in parallel

// ── Parse CLI args ────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const prefixArg = args.find(a => a.startsWith('--prefix='));
const STORAGE_PREFIX = prefixArg ? prefixArg.split('=')[1] : '';

// ── Init Firebase ─────────────────────────────────────────────────────────────
const SA_PATH = path.join(__dirname, 'service-account.json');
if (!fs.existsSync(SA_PATH)) {
  console.error('\n❌  Missing scripts/service-account.json');
  console.error('   Firebase Console → Project Settings → Service accounts');
  console.error('   → Generate new private key → save as scripts/service-account.json\n');
  process.exit(1);
}
const sa = require(SA_PATH);
admin.initializeApp({
  credential: admin.credential.cert(sa),
  storageBucket: `${sa.project_id}.appspot.com`,
});
const db = admin.firestore();
const bucket = admin.storage().bucket();

// ── Stats ─────────────────────────────────────────────────────────────────────
const stats = {
  total: 0, converted: 0, skipped: 0, errors: 0,
  bytesBefore: 0, bytesAfter: 0,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function log(msg)  { console.log(`[${ts()}] ${msg}`); }
function warn(msg) { console.warn(`[${ts()}] ⚠️   ${msg}`); }
function fail(msg) { console.error(`[${ts()}] ❌  ${msg}`); }
function ts() { return new Date().toISOString().slice(11, 23); }

/** Build Firebase Storage download URL from file name + access token. */
function makeDownloadUrl(name, token) {
  const encoded = encodeURIComponent(name);
  return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encoded}?alt=media&token=${token}`;
}

/** Get the existing download URL (token) stored in file metadata. */
async function getExistingDownloadUrl(file) {
  const [meta] = await file.getMetadata();
  const token = meta.metadata && meta.metadata.firebaseStorageDownloadTokens;
  return token ? makeDownloadUrl(file.name, token) : null;
}

/**
 * Convert buffer to WebP.
 * PNG → lossless WebP (preserves transparency, pixel-perfect).
 * JPEG → lossy WebP at WEBP_QUALITY (visually identical, ~40% smaller).
 */
async function convertToWebP(buffer, ext) {
  const isLossless = ext === '.png';
  return sharp(buffer)
    .webp({ quality: WEBP_QUALITY, lossless: isLossless })
    .toBuffer();
}

/** Upload WebP buffer to Storage, return its new download URL. */
async function uploadWebP(destName, buffer) {
  const token = uuidv4();
  await bucket.file(destName).save(buffer, {
    metadata: {
      contentType: 'image/webp',
      metadata: { firebaseStorageDownloadTokens: token },
    },
  });
  return makeDownloadUrl(destName, token);
}

// ── Firestore update ──────────────────────────────────────────────────────────

/**
 * Replace every Firestore occurrence of oldUrl with newUrl.
 * Searches all known collections + subcollections.
 * Returns the number of document fields updated.
 */
async function updateFirestoreRefs(oldUrl, newUrl, storagePath) {
  // Each entry: { ref, updates }
  const patches = [];
  const patch = (ref, updates) => patches.push({ ref, updates });

  // ── users.avatarUrl ──────────────────────────────────────────────────────
  const userSnaps = await db.collection('users')
    .where('avatarUrl', '==', oldUrl).get();
  userSnaps.forEach(d => patch(d.ref, { avatarUrl: newUrl }));

  // ── groups.memberAvatars (map field — infer userId from storage path) ────
  // avatars/{userId}/profile.ext  →  groups where memberAvatars.{userId} == oldUrl
  const avatarMatch = storagePath.match(/^avatars\/([^/]+)\//);
  if (avatarMatch) {
    const uid = avatarMatch[1];
    const userDoc = await db.collection('users').doc(uid).get();
    if (userDoc.exists) {
      const data = userDoc.data();
      const pairIds = new Set();
      if (data.pairId) pairIds.add(data.pairId);
      (data.pairIds || []).forEach(id => id && pairIds.add(id));

      for (const gid of pairIds) {
        const groupDoc = await db.collection('groups').doc(gid).get();
        if (!groupDoc.exists) continue;
        const memberAvatars = groupDoc.data().memberAvatars || {};
        if (memberAvatars[uid] === oldUrl) {
          patch(groupDoc.ref, { [`memberAvatars.${uid}`]: newUrl });
        }
      }
    }
  }

  // ── widgetData subcollection (collection group) ──────────────────────────
  for (const field of ['avatarUrl', 'photoUrl', 'photoForPartnerUrl']) {
    const snaps = await db.collectionGroup('widgetData')
      .where(field, '==', oldUrl).get();
    snaps.forEach(d => patch(d.ref, { [field]: newUrl }));
  }
  // array field: photoForPartnerUrls
  const wdArr = await db.collectionGroup('widgetData')
    .where('photoForPartnerUrls', 'array-contains', oldUrl).get();
  wdArr.forEach(d => {
    const urls = (d.data().photoForPartnerUrls || [])
      .map(u => u === oldUrl ? newUrl : u);
    patch(d.ref, { photoForPartnerUrls: urls });
  });

  // ── memories subcollection (collection group) ────────────────────────────
  for (const field of ['imageUrl', 'authorAvatar', 'musicCoverUrl']) {
    const snaps = await db.collectionGroup('memories')
      .where(field, '==', oldUrl).get();
    snaps.forEach(d => patch(d.ref, { [field]: newUrl }));
  }
  // array field: imageUrls
  const memArr = await db.collectionGroup('memories')
    .where('imageUrls', 'array-contains', oldUrl).get();
  memArr.forEach(d => {
    const urls = (d.data().imageUrls || [])
      .map(u => u === oldUrl ? newUrl : u);
    patch(d.ref, { imageUrls: urls });
  });

  // ── canvas strokes (collection group) ────────────────────────────────────
  const strokeSnaps = await db.collectionGroup('strokes')
    .where('imageUrl', '==', oldUrl).get();
  strokeSnaps.forEach(d => patch(d.ref, { imageUrl: newUrl }));

  if (patches.length === 0) return 0;

  // Batch commit (Firestore limit: 500 writes per batch)
  const BATCH_LIMIT = 499;
  for (let i = 0; i < patches.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    patches.slice(i, i + BATCH_LIMIT)
      .forEach(({ ref, updates }) => batch.update(ref, updates));
    await batch.commit();
  }
  return patches.length;
}

// ── Process one file ──────────────────────────────────────────────────────────

async function processFile(file) {
  const name = file.name;
  const ext = path.extname(name).toLowerCase();

  if (!IMAGE_EXTS.has(ext)) { stats.skipped++; return; }

  stats.total++;
  const newName = name.slice(0, -ext.length) + '.webp';

  try {
    const oldUrl = await getExistingDownloadUrl(file);
    if (!oldUrl) {
      warn(`No download token, skipping: ${name}`);
      stats.skipped++;
      return;
    }

    // Check if .webp already uploaded (previous partial run)
    const webpFile = bucket.file(newName);
    const [webpExists] = await webpFile.exists();

    const [buffer] = await file.download();
    const bytesBefore = buffer.length;

    if (DRY_RUN) {
      const webpBuf = await convertToWebP(buffer, ext);
      const bytesAfter = webpBuf.length;
      stats.bytesBefore += bytesBefore;
      stats.bytesAfter += bytesAfter;
      const pct = ((1 - bytesAfter / bytesBefore) * 100).toFixed(0);
      log(`DRY  ${name}  ${kb(bytesBefore)} → ${kb(bytesAfter)}  (-${pct}%)`);
      stats.converted++;
      return;
    }

    // 1. Upload WebP (skip if already uploaded from a previous partial run)
    let newUrl;
    let bytesAfter;
    if (webpExists) {
      // Re-use existing WebP, just get its URL
      newUrl = await getExistingDownloadUrl(webpFile);
      if (!newUrl) {
        fail(`${name}: webp exists but has no token — delete it manually and re-run`);
        stats.errors++;
        return;
      }
      const [webpBuf] = await webpFile.download();
      bytesAfter = webpBuf.length;
      warn(`Re-using existing WebP for ${name} (resuming partial run)`);
    } else {
      const webpBuf = await convertToWebP(buffer, ext);
      bytesAfter = webpBuf.length;
      newUrl = await uploadWebP(newName, webpBuf);
    }

    stats.bytesBefore += bytesBefore;
    stats.bytesAfter += bytesAfter;
    const pct = ((1 - bytesAfter / bytesBefore) * 100).toFixed(0);

    // 2. Update Firestore (safe to repeat — idempotent)
    const refs = await updateFirestoreRefs(oldUrl, newUrl, name);

    // 3. Delete original — ONLY after Firestore is updated
    await file.delete();

    stats.converted++;
    log(`✓  ${name}  ${kb(bytesBefore)} → ${kb(bytesAfter)}  (-${pct}%)  [${refs} refs]`);
  } catch (e) {
    fail(`${name}: ${e.message}`);
    stats.errors++;
  }
}

function kb(bytes) { return `${(bytes / 1024).toFixed(0)}KB`; }

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log('\n══════════════════════════════════════════════');
  console.log(`  WebP Migration  ${DRY_RUN ? '(DRY RUN — no changes)' : '⚡ LIVE MODE'}`);
  if (STORAGE_PREFIX) console.log(`  Prefix filter: ${STORAGE_PREFIX}`);
  console.log('══════════════════════════════════════════════\n');

  const [files] = await bucket.getFiles({ prefix: STORAGE_PREFIX });
  const imageFiles = files.filter(f => IMAGE_EXTS.has(path.extname(f.name).toLowerCase()));
  log(`Found ${files.length} total files, ${imageFiles.length} images to process\n`);

  // Process in parallel batches
  for (let i = 0; i < imageFiles.length; i += CONCURRENT) {
    await Promise.all(imageFiles.slice(i, i + CONCURRENT).map(processFile));
  }

  // Summary
  const saved = stats.bytesBefore - stats.bytesAfter;
  console.log('\n══════════════════════════════════════════════');
  console.log(`  Converted : ${stats.converted}`);
  console.log(`  Skipped   : ${stats.skipped}`);
  console.log(`  Errors    : ${stats.errors}`);
  console.log(`  Before    : ${mb(stats.bytesBefore)}`);
  console.log(`  After     : ${mb(stats.bytesAfter)}`);
  console.log(`  Saved     : ${mb(saved)}  (${stats.bytesBefore > 0 ? ((saved / stats.bytesBefore) * 100).toFixed(0) : 0}%)`);
  if (DRY_RUN) {
    console.log('\n  Run with --execute to apply these changes.');
  }
  console.log('══════════════════════════════════════════════\n');
}

function mb(bytes) { return `${(bytes / 1024 / 1024).toFixed(1)} MB`; }

main().catch(e => { fail(e.stack || e.message); process.exit(1); });
