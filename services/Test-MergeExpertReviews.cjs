const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {merge} = require('./MergeExpertReviews.cjs');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'region-review-'));
const id = '11111111-1111-4111-8111-111111111111';
const epoch = '22222222-2222-4222-8222-222222222222';
const instanceId = '66666666-6666-4666-8666-666666666666';
const markerId = '33333333-3333-4333-8333-333333333333';
const experiment = {format: 'region-lab.world-model-experiment', version: 1,
  status: 'complete', region_id: id, world_instance_id: instanceId,
  world_epoch: epoch, revision_before: 5,
  revision_after: 6, batch_id: 'batch-1', source_id: 'model-source', model_id: 'model',
  model_version: '1', hashes: {input_sha256: 'abc'}, markers: [{object_id: markerId,
    marker_name: '预测点 · quay · 2.40 m', region_position: [10, 20, 2.4],
    visual_marker_position: [10, 20, 22.4], sample_id: 'quay'}]};
const review = {format: 'region-lab.expert-review', version: 1, records: [{review_id:
  '44444444-4444-4444-8444-444444444444', at_utc: '2026-09-26T06:00:00Z',
   world_epoch: epoch, world_instance_id: instanceId, region_id: id,
   world_revision: 6, reviewer_account_id: id,
  marker_object_id: markerId, marker_name: '预测点 · quay · 2.40 m',
  marker_position: [10, 20, 22.4], reviewer_position: [12, 21, 2],
  assessment: 'inconsistent', note: '现场标尺高程不同'}]};
const eFile = path.join(root, 'experiment.json'), rFile = path.join(root, 'reviews.json');
function write() {fs.writeFileSync(eFile, JSON.stringify(experiment)); fs.writeFileSync(rFile, JSON.stringify(review));}
try {
  write();
  const joined = merge(eFile, rFile);
  assert.equal(joined.reviews.length, 1);
  assert.equal(joined.counts.inconsistent, 1);
  assert.equal(joined.reviews[0].prediction.sample_id, 'quay');
  assert.equal(joined.reviews[0].epoch_match, true);
  review.records[0].world_epoch = '55555555-5555-4555-8555-555555555555'; write();
  assert.equal(merge(eFile, rFile).reviews[0].epoch_match, false);
  assert.equal(merge(eFile, rFile).cautions.length, 2);
  review.records[0].world_instance_id = '77777777-7777-4777-8777-777777777777'; write();
  assert.throws(() => merge(eFile, rFile), /does not match/);
  review.records[0].world_instance_id = instanceId;
  review.records[0].marker_position[2] = 9; write();
  assert.throws(() => merge(eFile, rFile), /marker position changed/);
  review.records[0].marker_position[2] = 22.4;
  review.records[0].marker_object_id = id; write();
  assert.throws(() => merge(eFile, rFile), /does not match/);
   console.log('MERGE_EXPERT_REVIEWS 8/8 passed');
} finally {fs.rmSync(root, {recursive: true, force: true});}
