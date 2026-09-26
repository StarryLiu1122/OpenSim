/* Join local expert labels to a completed, authoritative world-model experiment.
 * This is an audit join, not a claim that a local JSON file is cryptographically
 * signed by its named reviewer. Node built-ins only. */
const fs = require('node:fs');
const crypto = require('node:crypto');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ASSESSMENTS = new Set(['unverified', 'consistent', 'inconsistent']);
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const finiteVector = value => Array.isArray(value) && value.length === 3
  && value.every(n => typeof n === 'number' && Number.isFinite(n));

function boundedJson(filename) {
  const bytes = fs.readFileSync(filename);
  if (bytes.length > 2 * 1024 * 1024) throw Error(`input exceeds 2 MiB: ${filename}`);
  return {value: JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, '')), sha256: hash(bytes)};
}

function merge(experimentFile, reviewFile) {
  const experiment = boundedJson(experimentFile);
  const reviews = boundedJson(reviewFile);
  const e = experiment.value, r = reviews.value;
  if (e?.format !== 'region-lab.world-model-experiment' || e.version !== 1
    || e.status !== 'complete' || !UUID.test(e.region_id) || !UUID.test(e.world_epoch)
    || !UUID.test(e.world_instance_id)
    || !Number.isInteger(e.revision_before) || !Number.isInteger(e.revision_after)
    || e.revision_after < e.revision_before || !Array.isArray(e.markers))
    throw Error('experiment must be a completed version-1 world-model experiment');
  if (r?.format !== 'region-lab.expert-review' || r.version !== 1
    || !Array.isArray(r.records) || r.records.length > 1000)
    throw Error('invalid version-1 expert review file');
  const markers = new Map();
  for (const marker of e.markers) {
    if (!UUID.test(marker.object_id) || markers.has(marker.object_id)
      || typeof marker.marker_name !== 'string' || !finiteVector(marker.region_position))
      throw Error('experiment has an invalid or duplicate marker');
    markers.set(marker.object_id, marker);
  }
  const seen = new Set(), joined = [], counts = {unverified: 0, consistent: 0, inconsistent: 0};
  for (const record of r.records) {
    if (!record || !UUID.test(record.review_id) || seen.has(record.review_id)
      || !UUID.test(record.reviewer_account_id) || !UUID.test(record.region_id)
      || !UUID.test(record.world_instance_id)
      || !UUID.test(record.world_epoch) || !UUID.test(record.marker_object_id)
      || !Number.isInteger(record.world_revision) || record.world_revision < 0
      || !ASSESSMENTS.has(record.assessment) || typeof record.note !== 'string'
      || record.note.length > 500 || !finiteVector(record.marker_position)
      || !finiteVector(record.reviewer_position)
      || typeof record.at_utc !== 'string'
      || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(record.at_utc)
      || !Number.isFinite(Date.parse(record.at_utc)))
      throw Error('review record has invalid fields or repeated review_id');
    seen.add(record.review_id);
    const marker = markers.get(record.marker_object_id);
    if (!marker || record.region_id !== e.region_id
      || record.world_instance_id !== e.world_instance_id
      || record.marker_name !== marker.marker_name
      || record.world_revision < e.revision_before)
      throw Error(`review ${record.review_id} does not match this experiment`);
    const visual = marker.visual_marker_position || marker.region_position;
    if (!finiteVector(visual) || record.marker_position.some((n, i) => Math.abs(n - visual[i]) > 0.01))
      throw Error(`review ${record.review_id} marker position changed; inspect before joining`);
    counts[record.assessment] += 1;
    joined.push({review: record, prediction: marker,
      epoch_match: record.world_epoch === e.world_epoch});
  }
  return {format: 'region-lab.world-model-review', version: 1,
    experiment: {batch_id: e.batch_id, source_id: e.source_id, model_id: e.model_id,
      model_version: e.model_version, region_id: e.region_id,
      world_instance_id: e.world_instance_id, world_epoch: e.world_epoch,
      revision_before: e.revision_before, revision_after: e.revision_after,
      hashes: e.hashes},
    inputs: {experiment_sha256: experiment.sha256, reviews_sha256: reviews.sha256},
    counts, reviews: joined,
    cautions: ['Expert review files are local exports; reviewer IDs are not signed.',
      ...(joined.some(item => !item.epoch_match)
        ? ['Some reviews were recorded after an authority restart; verify the persistent marker and scene state before interpreting them.'] : [])]};
}

function main(argv) {
  const args = {};
  for (const arg of argv) {
    const equals = arg.indexOf('=');
    if (!arg.startsWith('--') || equals < 3) throw Error(`invalid argument: ${arg}`);
    args[arg.slice(2, equals)] = arg.slice(equals + 1);
  }
  for (const key of ['experiment', 'reviews', 'output']) if (!args[key]) throw Error(`missing --${key}`);
  if (fs.existsSync(args.output)) throw Error('use a fresh output path');
  const result = merge(args.experiment, args.reviews);
  fs.writeFileSync(args.output, JSON.stringify(result, null, 2) + '\n', {flag: 'wx'});
  return result;
}

if (require.main === module) {
  try {
    const result = main(process.argv.slice(2));
    console.log(JSON.stringify({ok: true, counts: result.counts,
      output: process.argv.slice(2).find(arg => arg.startsWith('--output='))?.slice(9)}));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = {merge, main};
