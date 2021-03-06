(*
    ChibiOS/RT - Copyright (C) 2006-2013 Giovanni Di Sirio

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*)

%{^
#include <stdio.h>
#include <string.h>

#include "ch.h"
#include "hal.h"
#include "test.h"

#include "chprintf.h"
#include "shell.h"

#include "lwipthread.h"
#include "web/web.h"

#include "ff.h"

#include "usbcfg.h"

/**
 * @brief   Card monitor timer.
 */
static virtual_timer_t tmr;

/**
 * @brief   Debounce counter.
 */
static unsigned cnt;

/**
 * @brief   Card event sources.
 */
static event_source_t inserted_event, removed_event;

/*===========================================================================*/
/* Card insertion monitor.                                                   */
/*===========================================================================*/

#define POLLING_INTERVAL                10
#define POLLING_DELAY                   10

#define ats_blkIsInserted(p) blkIsInserted((BaseBlockDevice *) p)
%}

#include "share/atspre_define.hats"
#include "share/atspre_staload.hats"
staload UN = "prelude/SATS/unsafe.sats"

(* http://www.chibios.org/dokuwiki/doku.php?id=chibios:book:kernel#system_states *)
#define chss_init       0
#define chss_thread     1
#define chss_irqsusp    2
#define chss_irqdisable 3
#define chss_irqwait    4
#define chss_isr        5
#define chss_slock      6
#define chss_ilock      7
absvtype chss(s:int)
vtypedef chss_any = [s:int | chss_init <= s; s <= chss_ilock] chss(s)
vtypedef chss_iclass = [s:int | s == chss_slock || s == chss_ilock] chss(s)

#define POLLING_INTERVAL                10
#define POLLING_DELAY                   10U

abst@ype BaseBlockDevice = $extype"BaseBlockDevice"
abst@ype event_source_t  = $extype"event_source_t"
abst@ype virtual_timer_t = $extype"virtual_timer_t"
typedef systime_t = uint32
typedef vtfunc_t = (!chss(chss_isr) | ptr) -> void

extern praxi lemma_chss {s:int} (!chss(s)): [chss_init <= s; s <= chss_ilock] void

macdef inserted_event_p = $extval(cPtr0(event_source_t), "&inserted_event")
macdef removed_event_p  = $extval(cPtr0(event_source_t), "&removed_event")
macdef tmr_p            = $extval(cPtr0(virtual_timer_t), "&tmr")

extern fun MS2ST (uint): systime_t = "mac#"
extern fun chSysLock (!chss(chss_thread) >> chss(chss_slock) | ): void = "mac#"
extern fun chSysUnlock (!chss(chss_slock) >> chss(chss_thread) | ): void = "mac#"
extern fun chSysLockFromISR (!chss(chss_isr) >> chss(chss_ilock) | ): void = "mac#"
extern fun chSysUnlockFromISR (!chss(chss_ilock) >> chss(chss_isr) | ): void = "mac#"
extern fun chEvtBroadcastI (!chss_iclass | cPtr0(event_source_t)): void = "mac#"
extern fun chEvtObjectInit (!chss_any | cPtr0(event_source_t)): void = "mac#"
extern fun chVTSetI (!chss_iclass | cPtr0(virtual_timer_t), systime_t, vtfunc_t, cPtr0(BaseBlockDevice)): void = "mac#"
extern fun blkIsInserted (cPtr0(BaseBlockDevice)): bool = "mac#ats_blkIsInserted"

(* Insertion monitor timer callback function. *)
extern fun tmrfunc (!chss(chss_isr) | ptr): void = "mac#"
implement tmrfunc (pss | p) = {
  val bbdp = $UN.cast{cPtr0(BaseBlockDevice)}(p)

  val () = chSysLockFromISR (pss | )
  val cnt = $extval(int, "cnt")
  prval pss2 = pss
  val () = if cnt > 0 then
             if blkIsInserted (bbdp) then {
               extvar "cnt" = cnt - 1
               val cnt = $extval(int, "cnt")
               val () = if cnt = 0 then chEvtBroadcastI (pss2 | inserted_event_p)
             } else {
               extvar "cnt" = POLLING_INTERVAL
             }
           else if ~blkIsInserted(bbdp) then {
             extvar "cnt" = POLLING_INTERVAL
             val () = chEvtBroadcastI (pss2 | removed_event_p)
           }
  prval () = pss := pss2
  val () = chVTSetI (pss | tmr_p, MS2ST (POLLING_DELAY), tmrfunc, bbdp)
  val () = chSysUnlockFromISR (pss | )
}

(* Polling monitor start. *)
extern fun tmr_init (!chss(chss_thread) | ptr): void = "mac#"
implement tmr_init (pss | p) = {
  val bbdp = $UN.cast{cPtr0(BaseBlockDevice)}(p)

  val () = chEvtObjectInit (pss | inserted_event_p)
  val () = chEvtObjectInit (pss | removed_event_p)
  val () = chSysLock (pss | )
  extvar "cnt" = POLLING_INTERVAL
  val () = chVTSetI (pss | tmr_p, MS2ST (POLLING_DELAY), tmrfunc, bbdp)
  val () = chSysUnlock (pss | )
}

%{$
/*===========================================================================*/
/* FatFs related.                                                            */
/*===========================================================================*/

/**
 * @brief FS object.
 */
static FATFS SDC_FS;

/* FS mounted and ready.*/
static bool fs_ready = FALSE;

/* Generic large buffer.*/
static uint8_t fbuff[1024];

static FRESULT scan_files(BaseSequentialStream *chp, char *path) {
  FRESULT res;
  FILINFO fno;
  DIR dir;
  int i;
  char *fn;

#if _USE_LFN
  fno.lfname = 0;
  fno.lfsize = 0;
#endif
  res = f_opendir(&dir, path);
  if (res == FR_OK) {
    i = strlen(path);
    for (;;) {
      res = f_readdir(&dir, &fno);
      if (res != FR_OK || fno.fname[0] == 0)
        break;
      if (fno.fname[0] == '.')
        continue;
      fn = fno.fname;
      if (fno.fattrib & AM_DIR) {
        path[i++] = '/';
        strcpy(&path[i], fn);
        res = scan_files(chp, path);
        if (res != FR_OK)
          break;
        path[--i] = 0;
      }
      else {
        chprintf(chp, "%s/%s\r\n", path, fn);
      }
    }
  }
  return res;
}

/*===========================================================================*/
/* Command line related.                                                     */
/*===========================================================================*/

#define SHELL_WA_SIZE   THD_WORKING_AREA_SIZE(2048)
#define TEST_WA_SIZE    THD_WORKING_AREA_SIZE(256)

static void cmd_mem(BaseSequentialStream *chp, int argc, char *argv[]) {
  size_t n, size;

  (void)argv;
  if (argc > 0) {
    chprintf(chp, "Usage: mem\r\n");
    return;
  }
  n = chHeapStatus(NULL, &size);
  chprintf(chp, "core free memory : %u bytes\r\n", chCoreGetStatusX());
  chprintf(chp, "heap fragments   : %u\r\n", n);
  chprintf(chp, "heap free total  : %u bytes\r\n", size);
}

static void cmd_threads(BaseSequentialStream *chp, int argc, char *argv[]) {
  static const char *states[] = {CH_STATE_NAMES};
  thread_t *tp;

  (void)argv;
  if (argc > 0) {
    chprintf(chp, "Usage: threads\r\n");
    return;
  }
  chprintf(chp, "    addr    stack prio refs     state time\r\n");
  tp = chRegFirstThread();
  do {
    chprintf(chp, "%08lx %08lx %4lu %4lu %9s\r\n",
            (uint32_t)tp, (uint32_t)tp->p_ctx.r13,
            (uint32_t)tp->p_prio, (uint32_t)(tp->p_refs - 1),
            states[tp->p_state]);
    tp = chRegNextThread(tp);
  } while (tp != NULL);
}

static void cmd_test(BaseSequentialStream *chp, int argc, char *argv[]) {
  thread_t *tp;

  (void)argv;
  if (argc > 0) {
    chprintf(chp, "Usage: test\r\n");
    return;
  }
  tp = chThdCreateFromHeap(NULL, TEST_WA_SIZE, chThdGetPriorityX(),
                           TestThread, chp);
  if (tp == NULL) {
    chprintf(chp, "out of memory\r\n");
    return;
  }
  chThdWait(tp);
}

static void cmd_tree(BaseSequentialStream *chp, int argc, char *argv[]) {
  FRESULT err;
  uint32_t clusters;
  FATFS *fsp;

  (void)argv;
  if (argc > 0) {
    chprintf(chp, "Usage: tree\r\n");
    return;
  }
  if (!fs_ready) {
    chprintf(chp, "File System not mounted\r\n");
    return;
  }
  err = f_getfree("/", &clusters, &fsp);
  if (err != FR_OK) {
    chprintf(chp, "FS: f_getfree() failed\r\n");
    return;
  }
  chprintf(chp,
           "FS: %lu free clusters, %lu sectors per cluster, %lu bytes free\r\n",
           clusters, (uint32_t)SDC_FS.csize,
           clusters * (uint32_t)SDC_FS.csize * (uint32_t)MMCSD_BLOCK_SIZE);
  fbuff[0] = 0;
  scan_files(chp, (char *)fbuff);
}

static const ShellCommand commands[] = {
  {"mem", cmd_mem},
  {"threads", cmd_threads},
  {"test", cmd_test},
  {"tree", cmd_tree},
  {NULL, NULL}
};

static const ShellConfig shell_cfg1 = {
  (BaseSequentialStream *)&SDU2,
  commands
};

/*===========================================================================*/
/* Main and generic code.                                                    */
/*===========================================================================*/

/*
 * Card insertion event.
 */
static void InsertHandler(eventid_t id) {
  FRESULT err;

  (void)id;
  /*
   * On insertion SDC initialization and FS mount.
   */
  if (sdcConnect(&SDCD1))
    return;

  err = f_mount(&SDC_FS, "/", 1);
  if (err != FR_OK) {
    sdcDisconnect(&SDCD1);
    return;
  }
  fs_ready = TRUE;
}

/*
 * Card removal event.
 */
static void RemoveHandler(eventid_t id) {

  (void)id;
  sdcDisconnect(&SDCD1);
  fs_ready = FALSE;
}

/*
 * Green LED blinker thread, times are in milliseconds.
 */
static THD_WORKING_AREA(waThread1, 128);
static THD_FUNCTION(Thread1, arg) {

  (void)arg;
  chRegSetThreadName("blinker");
  while (true) {
    palToggleLine(LINE_ARD_D13);
    chThdSleepMilliseconds(fs_ready ? 250 : 500);
  }
}

/*
 * Application entry point.
 */
int main(void) {
  static thread_t *shelltp = NULL;
  static const evhandler_t evhndl[] = {
    InsertHandler,
    RemoveHandler
  };
  event_listener_t el0, el1;

  /*
   * System initializations.
   * - HAL initialization, this also initializes the configured device drivers
   *   and performs the board-specific initializations.
   * - Kernel initialization, the main() function becomes a thread and the
   *   RTOS is active.
   * - lwIP subsystem initialization using the default configuration.
   */
  halInit();
  chSysInit();
  lwipInit(NULL);

  /*
   * Initialize board LED.
   */
  palSetLineMode(LINE_ARD_D13, PAL_MODE_OUTPUT_PUSHPULL);

  /*
   * Initializes a serial-over-USB CDC driver.
   */
  sduObjectInit(&SDU2);
  sduStart(&SDU2, &serusbcfg);

  /*
   * Activates the USB driver and then the USB bus pull-up on D+.
   * Note, a delay is inserted in order to not have to disconnect the cable
   * after a reset.
   */
  usbDisconnectBus(serusbcfg.usbp);
  chThdSleepMilliseconds(1500);
  usbStart(serusbcfg.usbp, &usbcfg);
  usbConnectBus(serusbcfg.usbp);

  /*
   * Shell manager initialization.
   */
  shellInit();

  /*
   * Activates the serial driver 1 and SDC driver 1 using default
   * configuration.
   */
  sdStart(&SD1, NULL);
  sdcStart(&SDCD1, NULL);

  /*
   * Activates the card insertion monitor.
   */
  tmr_init(&SDCD1);

  /*
   * Creates the blinker thread.
   */
  chThdCreateStatic(waThread1, sizeof(waThread1), NORMALPRIO, Thread1, NULL);

  /*
   * Creates the HTTP thread (it changes priority internally).
   */
  chThdCreateStatic(wa_http_server, sizeof(wa_http_server), NORMALPRIO + 1,
                    http_server, NULL);

  /*
   * Normal main() thread activity, in this demo it does nothing except
   * sleeping in a loop and listen for events.
   */
  chEvtRegister(&inserted_event, &el0, 0);
  chEvtRegister(&removed_event, &el1, 1);
  while (true) {
    if (!shelltp && (SDU2.config->usbp->state == USB_ACTIVE))
      shelltp = shellCreate(&shell_cfg1, SHELL_WA_SIZE, NORMALPRIO);
    else if (chThdTerminatedX(shelltp)) {
      chThdRelease(shelltp);    /* Recovers memory of the previous shell.   */
      shelltp = NULL;           /* Triggers spawning of a new shell.        */
    }
    if (palReadPad(GPIOI, GPIOI_BUTTON_USER) != 0) {
    }
    chEvtDispatch(evhndl, chEvtWaitOneTimeout(ALL_EVENTS, MS2ST(500)));
  }
}
%}
