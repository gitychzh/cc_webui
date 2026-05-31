import fs from 'fs';
import path from 'path';
import os from 'os';

const LOG_LEVELS = { DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3 };

const LOG_DIR = path.join(os.homedir(), '.cloudcli', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'server.log');
const ERROR_LOG_FILE = path.join(LOG_DIR, 'server-error.log');
const MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_LOG_FILES = 5;

let currentLogLevel = LOG_LEVELS['INFO'];
let logStream = null;
let errorStream = null;

// Ensure log directory exists
try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
} catch (e) {
    // Directory may already exist
}

function rotateLogFile(filePath) {
    try {
        const stats = fs.statSync(filePath);
        if (stats.size < MAX_LOG_SIZE) return;
        for (let i = MAX_LOG_FILES - 1; i >= 1; i--) {
            const oldFile = `${filePath}.${i}`;
            const newFile = `${filePath}.${i + 1}`;
            try { fs.renameSync(oldFile, newFile); } catch (e) { /* file may not exist */ }
        }
        try { fs.renameSync(filePath, `${filePath}.1`); } catch (e) { /* ignore */ }
    } catch (e) { /* file may not exist yet */ }
}

function getStream(filePath) {
    rotateLogFile(filePath);
    return fs.createWriteStream(filePath, { flags: 'a' });
}

logStream = getStream(LOG_FILE);
errorStream = getStream(ERROR_LOG_FILE);

// Initialize log level from env
const envLevel = (process.env.LOG_LEVEL || 'INFO').toUpperCase();
if (LOG_LEVELS[envLevel] !== undefined) {
    currentLogLevel = LOG_LEVELS[envLevel];
}

function formatTimestamp() {
    return new Date().toISOString();
}

function stripAnsi(str) {
    return str.replace(/\x1b\[[0-9;]*m/g, '');
}

function writeToFile(stream, message) {
    try {
        stream.write(message + '\n');
    } catch (e) {
        // Stream may be closed during shutdown
    }
}

function formatArgs(args) {
    return args.map(a => {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === 'object') try { return JSON.stringify(a); } catch (e) { return String(a); }
        return String(a);
    }).join(' ');
}

function log(level, tag, ...args) {
    if (LOG_LEVELS[level] < currentLogLevel) return;

    const timestamp = formatTimestamp();
    const message = formatArgs(args);
    const formatted = `[${timestamp}] [${level}]${tag ? ` [${tag}]` : ''} ${message}`;
    const cleanMessage = stripAnsi(formatted);

    // Write clean (no ANSI) message to log file
    writeToFile(logStream, cleanMessage);

    // Errors also go to separate error log
    if (level === 'ERROR') {
        writeToFile(errorStream, cleanMessage);
    }
}

// Intercept console methods to also write to log files
// Save originals so we can still output to the terminal
const originalConsoleLog = console.log;
const originalConsoleError = console.error;
const originalConsoleWarn = console.warn;

function interceptedLog(level, args) {
    const timestamp = formatTimestamp();
    const message = formatArgs(args);
    const cleanMessage = stripAnsi(`[${timestamp}] [${level}] ${message}`);

    writeToFile(logStream, cleanMessage);
    if (level === 'ERROR') {
        writeToFile(errorStream, cleanMessage);
    }
}

console.log = function (...args) {
    interceptedLog('INFO', args);
    originalConsoleLog.apply(console, args);
};

console.error = function (...args) {
    interceptedLog('ERROR', args);
    originalConsoleError.apply(console, args);
};

console.warn = function (...args) {
    interceptedLog('WARN', args);
    originalConsoleWarn.apply(console, args);
};

// Direct logger API for structured logging with tags
const logger = {
    debug: (tag, ...args) => {
        log('DEBUG', tag, ...args);
        if (LOG_LEVELS['DEBUG'] >= currentLogLevel) originalConsoleLog.apply(console, [`[DEBUG]${tag ? ` [${tag}]` : ''}`, ...args]);
    },
    info: (tag, ...args) => {
        log('INFO', tag, ...args);
        originalConsoleLog.apply(console, [`[INFO]${tag ? ` [${tag}]` : ''}`, ...args]);
    },
    warn: (tag, ...args) => {
        log('WARN', tag, ...args);
        originalConsoleWarn.apply(console, [`[WARN]${tag ? ` [${tag}]` : ''}`, ...args]);
    },
    error: (tag, ...args) => {
        log('ERROR', tag, ...args);
        originalConsoleError.apply(console, [`[ERROR]${tag ? ` [${tag}]` : ''}`, ...args]);
    },
    log: (...args) => {
        log('INFO', '', ...args);
        originalConsoleLog.apply(console, args);
    },

    flush: () => {
        if (logStream) logStream.end();
        if (errorStream) errorStream.end();
        logStream = getStream(LOG_FILE);
        errorStream = getStream(ERROR_LOG_FILE);
    },

    // Restore original console methods (for testing or shutdown)
    restoreConsole: () => {
        console.log = originalConsoleLog;
        console.error = originalConsoleError;
        console.warn = originalConsoleWarn;
    },
};

export { logger, LOG_DIR, LOG_FILE, ERROR_LOG_FILE };