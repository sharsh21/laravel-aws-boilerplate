<?php

use Monolog\Formatter\JsonFormatter;
use Monolog\Handler\StreamHandler;

return [

    /*
    | On ECS: LOG_CHANNEL=daily is injected by Terraform.
    | Laravel writes to storage/logs/laravel-YYYY-MM-DD.log.
    | The CloudWatch agent sidecar reads that file and ships it to
    | CloudWatch log group: /ecs/{app}-{env}/laravel
    */
    'default' => env('LOG_CHANNEL', 'daily'),

    'deprecations' => [
        'channel' => env('LOG_DEPRECATIONS_CHANNEL', 'null'),
        'trace'   => env('LOG_DEPRECATIONS_TRACE', false),
    ],

    'channels' => [

        /*
        |----------------------------------------------------------------------
        | stderr (default for ECS)
        |
        | Writes JSON to stderr → Docker captures it → awslogs driver
        | sends it to CloudWatch Logs automatically.
        |
        | Query in CloudWatch Log Insights:
        |   fields @timestamp, level, message, context.exception
        |   | filter level = "error"
        |   | sort @timestamp desc
        |----------------------------------------------------------------------
        */
        'stderr' => [
            'driver'    => 'monolog',
            'level'     => env('LOG_LEVEL', 'debug'),
            'handler'   => StreamHandler::class,
            'formatter' => JsonFormatter::class,
            'with'      => [
                'stream' => 'php://stderr',
            ],
        ],

        'stack' => [
            'driver'            => 'stack',
            'channels'          => explode(',', env('LOG_STACK', 'stderr')),
            'ignore_exceptions' => false,
        ],

        'single' => [
            'driver' => 'single',
            'path'   => storage_path('logs/laravel.log'),
            'level'  => env('LOG_LEVEL', 'debug'),
            'replace_placeholders' => true,
        ],

        'daily' => [
            'driver' => 'daily',
            'path'   => storage_path('logs/laravel.log'),
            'level'  => env('LOG_LEVEL', 'debug'),
            'days'   => 14,
            'replace_placeholders' => true,
        ],

        'null' => [
            'driver'  => 'monolog',
            'handler' => \Monolog\Handler\NullHandler::class,
        ],

        'emergency' => [
            'path' => storage_path('logs/laravel.log'),
        ],
    ],

];
