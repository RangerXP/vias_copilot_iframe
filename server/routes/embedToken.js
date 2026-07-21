import express from 'express';
import { getEmbedToken } from '../services/pbiClient.js';

const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const token = await getEmbedToken({
      workspaceId: process.env.WORKSPACE_ID,
      reportId: process.env.REPORT_ID,
      datasetId: process.env.DATASET_ID
    });
    res.json(token);
  } catch (err) {
    console.error('[embedToken]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
