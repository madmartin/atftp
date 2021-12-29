/* hey emacs! -*- Mode: C; c-file-style: "k&r"; indent-tabs-mode: nil -*- */
/*
 * tftpd_pcre.c
 *    functions to remmap file name requested by tftp clients according
 *    to regular expression rules
 *
 * $Id: tftpd_pcre.c,v 1.2 2003/04/25 00:16:19 jp Exp $
 *
 * Copyright (c) 2003 Jean-Pierre Lefebvre <helix@step.polymtl.ca>
 *                and Remi Lefebvre <remi@debian.org>
 *
 * The PCRE code is provided by Jeff Miller <jeff.miller@transact.com.au>
 *
 * Copyright (c) 2003 Jeff Miller <jeff.miller@transact.com.au>
 *
 * atftp is free software; you can redistribute them and/or modify them
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 *
 */

#include "config.h"

#if HAVE_PCRE

#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "tftp_def.h"
#include "config.h"
#include "logger.h"

#include "tftpd_pcre.h"

/* create a pattern list from a file */
/* return 0 on success, -1 otherwise */
tftpd_pcre_self_t *tftpd_pcre_open(char *filename)
{
     int linecount;
     PCRE2_SIZE erroffset;
     PCRE2_SIZE *len;
     int errnumber;
     int matches;
     char line[MAXLEN];
     FILE *fh;
     int subnum;
     PCRE2_UCHAR **substrlist;
     pcre2_code *file_re;
     pcre2_match_data *match_data;
     tftpd_pcre_self_t *self;
     tftpd_pcre_pattern_t *pat, **curpatp;

     /* open file */
     if ((fh = fopen(filename, "r")) == NULL)
     {
          logger(LOG_ERR, "Cannot open %s for reading: %s",
                 filename, strerror(errno));
          return NULL;
     }

     /* compile pattern for lines */
     logger(LOG_DEBUG, "Using file pattern %s", TFTPD_PCRE_FILE_PATTERN);
     if ((file_re = pcre2_compile((PCRE2_SPTR)TFTPD_PCRE_FILE_PATTERN, PCRE2_ZERO_TERMINATED, 0,
                                 &errnumber, &erroffset, NULL)) == NULL)
     {
          logger(LOG_ERR, "PCRE file pattern failed to compile");
          return NULL;
     }

     /* allocate header  and copy info */
     if ((self = calloc(1, sizeof(tftpd_pcre_self_t))) == NULL)
     {
          logger(LOG_ERR, "calloc failed");
          return NULL;
     }
     self->lock = (pthread_mutex_t) PTHREAD_MUTEX_INITIALIZER;
     Strncpy(self->filename, filename, MAXLEN);

     /* read patterns */
     for (linecount = 1, curpatp = &self->list;
          fgets(line, MAXLEN, fh) != NULL;
          linecount++, curpatp = &pat->next)
     {
          logger(LOG_DEBUG,"file: %s line: %d value: %s",
                 filename, linecount, line);

          /* allocate space for pattern info */
          if ((pat = (tftpd_pcre_pattern_t *)calloc(1,sizeof(tftpd_pcre_pattern_t))) == NULL)
          {
               tftpd_pcre_close(self);
               return NULL;
          }
          *curpatp = pat;

          /* for each pattern read, compile and store the pattern */
          match_data = pcre2_match_data_create_from_pattern(file_re, NULL);
          matches = pcre2_match(file_re, (PCRE2_SPTR)line, (int)(strlen(line)),
                                0, 0, match_data, NULL);

          /* log substring to help with debugging */
          pcre2_substring_list_get(match_data, &substrlist, NULL);
          for(subnum = 0; subnum < matches; subnum++)
          {
               logger(LOG_DEBUG,"file: %s line: %d substring: %d value: %s",
                      filename, linecount, subnum, substrlist[subnum]);
          }
          pcre2_substring_list_free((const PCRE2_UCHAR **)substrlist);

          if (matches != 3)
          {
               logger(LOG_ERR, "error with pattern in file \"%s\" line %d",
                      filename, linecount);
               tftpd_pcre_close(self);
               pcre2_match_data_free(match_data);
               pcre2_code_free(file_re);
               return NULL;
          }
          /* remember line number */
          pat->linenum = linecount;
          /* extract left side */
          pcre2_substring_get_bynumber(match_data, 1,
                                       (PCRE2_UCHAR **)&pat->pattern, (PCRE2_SIZE *)&len);
          /* extract right side */
          pcre2_substring_get_bynumber(match_data, 2,
                                       (PCRE2_UCHAR **)&pat->right_str, (PCRE2_SIZE *)&len);

          logger(LOG_DEBUG,"pattern: %s right_str: %s", pat->pattern, pat->right_str);

          if ((pat->left_re = pcre2_compile((PCRE2_SPTR)pat->pattern, PCRE2_ZERO_TERMINATED, 0,
                                           &errnumber, &erroffset, NULL)) == NULL)
          {
               /* compilation failed*/
               PCRE2_UCHAR buffer[256];
               pcre2_get_error_message(errnumber, buffer, sizeof(buffer));
               logger(LOG_ERR,
                      "PCRE compilation failed in file \"%s\" line %d at %d: %s",
                      filename, linecount,
                      erroffset, buffer);
               /* close file */
               fclose(fh);
               /* clean up */
               pcre2_code_free(file_re);
               pcre2_match_data_free(match_data);
               tftpd_pcre_close(self);
               return NULL;
          }
     }
     /* clean up */
     pcre2_code_free(file_re);
     pcre2_match_data_free(match_data);
     /* close file */
     fclose(fh);
     return self;
}

/* return filename being used */
/* returning a char point directly is a little risking when
 * using thread, but as we're using this before threads
 * are created we should be able to get away with it
 */
char *tftpd_pcre_getfilename(tftpd_pcre_self_t *self)
{
     return self->filename;
}

/* search for a replacement and return a string after substitution */
/* if no match is found return -1 */
int tftpd_pcre_sub(tftpd_pcre_self_t *self, char *outstr, int outlen, char *str)
{
     int matches;
     pcre2_match_data *match_data;
     tftpd_pcre_pattern_t *pat;

     /* lock for duration */
     pthread_mutex_lock(&self->lock);

     logger(LOG_DEBUG, "Looking to match \"%s\"", str);
     /* interate over pattern list */
     for(pat = self->list; pat != NULL; pat = pat->next)
     {
          logger(LOG_DEBUG,"Attempting to match \"%s\"", pat->pattern);

          /* attempt match */
          match_data = pcre2_match_data_create_from_pattern(pat->left_re, NULL);
          matches = pcre2_match(pat->left_re, (PCRE2_SPTR)str, (int)(strlen(str)),
                                0, 0, match_data, NULL);
          /* no match so we try again */
          if (matches == PCRE2_ERROR_NOMATCH)
               continue;
          /* error in making a match - log and attempt to continue */
          if (matches < 0)
          {
               logger(LOG_WARNING,
                      "PCRE Matching error %d", matches);
               continue;
          }
          /* we have a match  - carry out substitution */
          logger(LOG_DEBUG,"Pattern \"%s\" matches", pat->pattern);
          pcre2_substitute(pat->left_re, (PCRE2_SPTR)str, (PCRE2_SIZE)(strlen(str)),
                           0, 0, match_data, NULL, (PCRE2_SPTR)pat->right_str,
                           (PCRE2_SIZE)(strlen((const char *)pat->right_str)),
                           (PCRE2_UCHAR *)outstr, (PCRE2_SIZE *)&outlen);
          logger(LOG_DEBUG,"outstr: \"%s\"", outstr);
          pcre2_match_data_free(match_data);
          pthread_mutex_unlock(&self->lock);
          return 0;
     }
     logger(LOG_DEBUG, "Failed to match \"%s\"", str);
     pcre2_match_data_free(match_data);
     pthread_mutex_unlock(&self->lock);
     return -1;
}

/* clean up and displose of anything we set up*/
void tftpd_pcre_close(tftpd_pcre_self_t *self)
{
     tftpd_pcre_pattern_t *next, *cur;

     /* free up list */
     pthread_mutex_lock(&self->lock);

     cur = self->list;
     while (cur != NULL)
     {
          next = cur->next;
          pcre2_substring_free(cur->pattern);
          pcre2_substring_free(cur->right_str);
          pcre2_code_free(cur->left_re);
          free(cur);
          cur = next;
     }
     pthread_mutex_unlock(&self->lock);
     free(self);
}

#endif
