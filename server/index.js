import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import embedTokenRoute from './routes/embedToken.js';
import chatRoute from './routes/chat.js';
import contextRoute from './routes/context.js';

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();

app.use(cors({
  origin: [
    `http://localhost:${process.env.PORT || 3000}`,
    'http://localhost:5173'
  ],
  methods: ['GET', 'POST']
}));
app.use(express.json());
app.use(express.static(join(__dirname, '..', 'frontend')));

app.use('/api/embed-token', embedTokenRoute);
app.use('/api/chat', chatRoute);
app.use('/api/context', contextRoute);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`PBIE local server running on http://localhost:${port}`);
});
