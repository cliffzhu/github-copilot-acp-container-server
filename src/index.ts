import "dotenv/config";

import { createApp } from "./app";
import { createConfig } from "./config";
import { createLogger } from "./logger";

const config = createConfig();
const logger = createLogger();
const app = createApp(config);

app.listen(config.PORT, config.HOST, () => {
  logger.info(
    {
      host: config.HOST,
      port: config.PORT,
      authRequired: config.AUTH_REQUIRED,
      autoUpdate: config.AUTO_UPDATE,
    },
    "Server started",
  );
});
