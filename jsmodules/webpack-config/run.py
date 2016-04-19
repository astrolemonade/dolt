#!/usr/bin/env python

import argparse, os, subprocess, sys

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=str, help='destination js file')
    parser.add_argument('--src', type=str, help='source of main js file')
    parser.add_argument('mode', type=str, help='"production" or "development"')
    args = parser.parse_args()

    env = {
        'NODE_ENV': args.mode,
        'BABEL_ENV': args.mode,
    }
    env.update(os.environ)
    subprocess.check_call(
            ['node_modules/.bin/webpack',
                '--config', 'node_modules/@attic/webpack-config/index.js', args.src, args.out],
            env=env, shell=False)


if __name__ == "__main__":
    main()
