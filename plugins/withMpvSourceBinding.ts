import {
  type ConfigPlugin,
  withProjectBuildGradle,
  withSettingsGradle,
} from "expo/config-plugins";

const binding = "../modules/mpv-player/android/libmpv-binding/consumer";
const marker = "// Streamyfin libmpv source binding";

const withMpvSourceBinding: ConfigPlugin = (config) => {
  config = withSettingsGradle(config, (config) => {
    if (!config.modResults.contents.includes(marker)) {
      config.modResults.contents += `
${marker}
include ':streamyfin-libmpv-binding'
project(':streamyfin-libmpv-binding').projectDir = new File(rootDir, '${binding}')
`;
    }
    return config;
  });
  return withProjectBuildGradle(config, (config) => {
    if (!config.modResults.contents.includes(marker)) {
      config.modResults.contents += `
${marker}
apply from: new File(rootDir, '${binding}/substitution.gradle')
`;
    }
    return config;
  });
};

export default withMpvSourceBinding;
