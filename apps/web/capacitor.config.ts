import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "in.koliwadadhaba.pos",
  appName: "Koli Wada Dhaba POS",
  webDir: "dist",
  server: {
    androidScheme: "https",
    cleartext: false,
  },
};

export default config;
