import fs from 'node:fs';
import path from 'node:path';
import { serverDirectory } from '../server-directory.js';
// Webpack is imported lazily in runWebpackCompiler.
import getPublicLibConfig from '../../webpack.config.js';

export default function getWebpackServeMiddleware() {
    /**
     * A very spartan recreation of webpack-dev-middleware.
     * @param {import('express').Request} req Request object.
     * @param {import('express').Response} res Response object.
     * @param {import('express').NextFunction} next Next function.
     * @type {import('express').RequestHandler}
     */
    function devMiddleware(req, res, next) {
        const publicLibConfig = getPublicLibConfig();
        const outputPath = publicLibConfig.output?.path;
        const outputFile = publicLibConfig.output?.filename;
        const parsedPath = path.parse(req.path);

        if (req.method === 'GET' && parsedPath.dir === '/' && parsedPath.base === outputFile) {
            return res.sendFile(outputFile, { root: outputPath });
        }

        next();
    }

    /**
     * Wait until Webpack is done compiling.
     * @param {object} param Parameters.
     * @param {boolean} [param.forceDist=false] Whether to force the use the /dist folder.
     * @param {boolean} [param.pruneCache=false] Whether to prune old cache directories before compiling.
     * @returns {Promise<void>}
     */
    devMiddleware.runWebpackCompiler = async ({ forceDist = false, pruneCache = false } = {}) => {
        // NativeTavern: use the prebuilt bundle shipped with the app.
        // The bundle is produced once by Scripts/build-lib-bundle.sh and is
        // byte-identical in purpose to what this compiler would emit.
        const prebuilt = path.join(serverDirectory, 'public/lib.bundle.js');
        if (fs.existsSync(prebuilt)) {
            console.log('Using prebuilt frontend libraries.');
            return Promise.resolve();
        }

        console.log();
        console.log('Compiling frontend libraries...');

        const publicLibConfig = getPublicLibConfig({ forceDist, pruneCache });
        const { default: webpack } = await import('webpack');
        const compiler = webpack(publicLibConfig);

        return new Promise((resolve) => {
            compiler.run((_error, stats) => {
                const output = stats?.toString(publicLibConfig.stats);
                if (output) {
                    console.log(output);
                    console.log();
                }
                compiler.close(() => {
                    resolve();
                });
            });
        });
    };

    return devMiddleware;
}
