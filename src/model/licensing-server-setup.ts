import * as core from '@actions/core';
import fs from 'fs';

class LicensingServerSetup {
  public static Setup(unityLicensingServer, actionFolder: string) {
    const servicesConfigPath = `${actionFolder}/unity-config/services-config.json`;
    const servicesConfigPathTemplate = `${servicesConfigPath}.template`;
    if (!fs.existsSync(servicesConfigPathTemplate)) {
      core.error(`Missing services config ${servicesConfigPathTemplate}`);

      return;
    }

    // Extract the first URL if multiple are provided (semicolon-separated)
    const firstServer = unityLicensingServer.split(';')[0].trim();

    let servicesConfig = fs.readFileSync(servicesConfigPathTemplate).toString();
    servicesConfig = servicesConfig.replace('%URL%', firstServer);
    fs.writeFileSync(servicesConfigPath, servicesConfig);
  }
}

export default LicensingServerSetup;
