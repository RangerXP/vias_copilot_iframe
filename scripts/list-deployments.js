import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';
import dotenv from 'dotenv';
dotenv.config();

const c = new AIProjectClient(process.env.FOUNDRY_PROJECT_ENDPOINT, new DefaultAzureCredential());

console.log('=== Deployments ===');
for await (const dep of c.deployments.list()) {
  console.log(' ', dep.name, '| type:', dep.type, '| model:', JSON.stringify(dep).slice(0, 200));
}

console.log('\n=== Agents ===');
for await (const ag of c.agents.listAgents()) {
  console.log(' ', ag.id, ag.name, '| model:', ag.model);
}
