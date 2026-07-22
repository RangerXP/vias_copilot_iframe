import 'dotenv/config';
import { queryFabricAgent } from '../server/services/fabricAgent.js';

const queries = {
  countryRegion: `EVALUATE DISTINCT(dim_country[Region])`,
  clientHomeRegion: `EVALUATE DISTINCT(dim_client[HomeRegion])`,
  clientNames: `EVALUATE TOPN(15, VALUES(dim_client[ClientName]))`
};

for (const [label, daxQuery] of Object.entries(queries)) {
  try {
    const result = await queryFabricAgent({ question: label, daxQuery });
    console.log(`\n=== ${label} ===`);
    console.log(result);
  } catch (err) {
    console.log(`\n=== ${label} FAILED ===`);
    console.log(err.message);
  }
}
