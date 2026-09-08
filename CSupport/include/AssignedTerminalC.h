#ifndef ASSIGNED_TERMINAL_C_H
#define ASSIGNED_TERMINAL_C_H

int assigned_signal_open(void);
int assigned_signal_read_fd(void);
int assigned_signal_wake(void);
int assigned_signal_install(void);
void assigned_signal_restore(void);
void assigned_signal_close(void);

#endif
