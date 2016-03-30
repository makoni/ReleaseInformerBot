'use strict';

const gulp = require('gulp');
const jasmine = require('gulp-jasmine');
const eslint = require('gulp-eslint');

gulp.task('lint', function () {
    return gulp.src(['**/*.js','*.js','!node_modules/**'])
        .pipe(eslint(
            {
                "parserOptions": {
                    "ecmaVersion": 6,
                    "sourceType": "module",
                    "ecmaFeatures": {
                        "jsx": true
                    }
                },
                "rules": {
                    "semi": 2,
                    "valid-jsdoc": 1,
                    "block-scoped-var" : 2,
                    "eqeqeq" : 2,
                    "no-invalid-this" : 2,
                    "no-multi-spaces" : 2,
                    "no-unmodified-loop-condition" : 2,
                    "no-unused-expressions" : 2,
                    "no-unused-labels" : 2,
                    "no-shadow" : 2,
                    "no-unused-vars" : 1,
                    "arrow-spacing" : 2,
                    "no-var" : 2
                }
            }
        ))
        .pipe(eslint.format())
        // To have the process exit with an error code (1) on
        // lint error, return the stream and pipe to failAfterError last.
        .pipe(eslint.failAfterError());
});

gulp.task('default', ['lint'], function() {
    gulp.src('spec/BotSpec.js')
		.pipe(jasmine());
});
