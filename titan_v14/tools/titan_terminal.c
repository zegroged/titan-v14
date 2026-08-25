/*******************************************************************************
 * PROJECT TITAN V14: Zero-Trust PC Terminal
 *******************************************************************************
 * FELSEFE: PC = DÜŞMAN TOPRAK
 * Bu yazılım SADECE bir boru (pipe). Hiçbir kriptografi, hiçbir key bilgisi,
 * hiçbir protokol bilgisi İÇERMEZ.
 *
 *   stdin  → byte → RED UART TX (seri port)
 *   RED UART RX → byte → stdout
 *
 * DERLEME:
 *   Windows: gcc -static -O2 -o titan_terminal.exe titan_terminal.c
 *   Linux:   gcc -static -O2 -o titan_terminal titan_terminal.c
 *
 * KULLANIM:
 *   Windows: titan_terminal.exe COM3
 *   Linux:   titan_terminal /dev/ttyUSB0
 *
 * GÜVENLİK:
 *   - RAM'de veri max 1 byte tutulur (streaming)
 *   - Key bilgisi YOK, protokol bilgisi YOK
 *   - Bağımlılık SIFIR (sadece POSIX/Win32 system calls)
 *   - Read-only medyadan çalıştırılabilir
 ******************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#ifdef _WIN32
    #include <windows.h>
    #include <io.h>
    #include <fcntl.h>
    typedef HANDLE port_t;
    #define INVALID_PORT INVALID_HANDLE_VALUE
#else
    #include <unistd.h>
    #include <fcntl.h>
    #include <termios.h>
    #include <errno.h>
    #include <sys/select.h>
    typedef int port_t;
    #define INVALID_PORT (-1)
#endif

static volatile int running = 1;

static void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

/*******************************************************************************
 * SERIAL PORT OPEN (115200 8N1)
 ******************************************************************************/
static port_t port_open(const char *name) {
#ifdef _WIN32
    HANDLE h = CreateFileA(name, GENERIC_READ | GENERIC_WRITE,
                           0, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return INVALID_PORT;

    DCB dcb = {0};
    dcb.DCBlength = sizeof(dcb);
    GetCommState(h, &dcb);
    dcb.BaudRate = 115200;
    dcb.ByteSize = 8;
    dcb.Parity   = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    SetCommState(h, &dcb);

    COMMTIMEOUTS ct = {0};
    ct.ReadIntervalTimeout = 1;         /* Return immediately if no data */
    ct.ReadTotalTimeoutMultiplier = 0;
    ct.ReadTotalTimeoutConstant = 1;    /* 1ms timeout */
    SetCommTimeouts(h, &ct);
    return h;
#else
    int fd = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return INVALID_PORT;

    struct termios tty;
    memset(&tty, 0, sizeof(tty));
    tcgetattr(fd, &tty);

    cfsetispeed(&tty, B115200);
    cfsetospeed(&tty, B115200);

    tty.c_cflag = CS8 | CLOCAL | CREAD;
    tty.c_iflag = 0;
    tty.c_oflag = 0;
    tty.c_lflag = 0;
    tty.c_cc[VMIN]  = 0;
    tty.c_cc[VTIME] = 1;  /* 100ms timeout */

    tcsetattr(fd, TCSANOW, &tty);
    return fd;
#endif
}

/*******************************************************************************
 * SERIAL PORT CLOSE
 ******************************************************************************/
static void port_close(port_t p) {
#ifdef _WIN32
    CloseHandle(p);
#else
    close(p);
#endif
}

/*******************************************************************************
 * SERIAL READ (non-blocking, 1 byte)
 ******************************************************************************/
static int port_read(port_t p, unsigned char *byte) {
#ifdef _WIN32
    DWORD n = 0;
    ReadFile(p, byte, 1, &n, NULL);
    return (int)n;
#else
    return (int)read(p, byte, 1);
#endif
}

/*******************************************************************************
 * SERIAL WRITE (1 byte)
 ******************************************************************************/
static int port_write(port_t p, unsigned char byte) {
#ifdef _WIN32
    DWORD n = 0;
    WriteFile(p, &byte, 1, &n, NULL);
    return (int)n;
#else
    return (int)write(p, &byte, 1);
#endif
}

/*******************************************************************************
 * STDIN NON-BLOCKING CHECK
 ******************************************************************************/
#ifdef _WIN32
static int stdin_has_data(void) {
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    DWORD events = 0;
    INPUT_RECORD ir;
    if (PeekConsoleInput(h, &ir, 1, &events) && events > 0) {
        if (ir.EventType == KEY_EVENT && ir.Event.KeyEvent.bKeyDown) {
            return 1;
        }
        ReadConsoleInput(h, &ir, 1, &events);  /* consume non-key events */
    }
    return 0;
}
#else
static int stdin_has_data(void) {
    fd_set fds;
    struct timeval tv = {0, 0};
    FD_ZERO(&fds);
    FD_SET(STDIN_FILENO, &fds);
    return select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0;
}
#endif

/*******************************************************************************
 * MAIN LOOP — ZERO TRUST PIPE
 ******************************************************************************/
int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "TITAN V14 Zero-Trust Terminal\n");
        fprintf(stderr, "Usage: %s <port>\n", argv[0]);
        fprintf(stderr, "  Windows: %s COM3\n", argv[0]);
        fprintf(stderr, "  Linux:   %s /dev/ttyUSB0\n", argv[0]);
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    port_t port = port_open(argv[1]);
    if (port == INVALID_PORT) {
        fprintf(stderr, "ERROR: Cannot open %s\n", argv[1]);
        return 1;
    }

    fprintf(stderr, "TITAN V14 Terminal — %s @ 115200 8N1\n", argv[1]);
    fprintf(stderr, "Press Ctrl+C to exit\n");
    fprintf(stderr, "---\n");

#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif

    /* Main loop — 1 byte at a time, no buffering */
    unsigned char b;
    while (running) {

        /* UART RX → stdout (1 byte) */
        if (port_read(port, &b) == 1) {
            fputc(b, stdout);
            fflush(stdout);
        }

        /* stdin → UART TX (1 byte) */
        if (stdin_has_data()) {
            int c = fgetc(stdin);
            if (c == EOF) break;
            b = (unsigned char)c;
            port_write(port, b);
        }
    }

    port_close(port);
    fprintf(stderr, "\nSession terminated.\n");
    return 0;
}
