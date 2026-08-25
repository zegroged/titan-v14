/**
 * @file tamper.h
 * @brief Tamper Detection — Reed Switch + Limit Switch
 */
#ifndef CALLWHITE_TAMPER_H
#define CALLWHITE_TAMPER_H

void tamper_init(void);

/** Trigger FPGA kill signal (PC13) */
void tamper_kill_fpga(void);

#endif
