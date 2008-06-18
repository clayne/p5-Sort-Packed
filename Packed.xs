/* -*- Mode: C -*- */

#define PERL_NO_GET_CONTEXT 1

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include "merge.h"

#define BYTE_ORDER_BE 0
#define BYTE_ORDER_LE 1
#define BYTE_ORDER_LAST BYTE_ORDER_LE

#define TYPE_UNSIGNED 0
#define TYPE_SIGNED 1
#define TYPE_FLOAT 2
#define TYPE_FLOAT_X86 3
#define TYPE_LAST TYPE_FLOAT_X86

#define CUTOFF 16

static void
dump_keys(char *name, unsigned char *pv, UV nelems, UV record_size, UV offset) {
    int i;
    fprintf(stderr, "%s\n", name);
    for (i = 0; i < nelems; i++) {
        int j;
        fprintf(stderr, "%04x:", i);
        for (j = offset; j < record_size; j++) {
            fprintf(stderr, " %02x", *(pv + i * record_size + j));
        }
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "\n");
}

dump_pos(UV *pos) {
    int i, last = 0;
    fprintf(stderr, "\n\npos:");
    for (i=0; i < 256; i++) {
        if (pos[i] != last) 
            fprintf(stderr, "%02x: %d, ", i, pos[i] - last);
        last = pos[i];
    }
    fprintf(stderr, "\n");
}

static void
radixsort(unsigned char *pv, UV nelems, UV record_size, UV offset) {
    if (nelems > CUTOFF) {
        UV count[256];
        UV pos[256];
        UV i, last, offset1;
        unsigned char *ptr, *end;

        /* dump_keys("in", pv, nelems, record_size, offset); */

        for (i = 0; i < 256; i++)
            count[i] = 0;
        ptr = pv + offset;
        end = ptr + nelems * record_size;
        while (ptr < end) {
            count[*ptr]++;
            ptr += record_size;
        }
        
        if (offset + 1 == record_size) {
            ptr = pv + offset;
            for (i = 0; i < 256; i++) {
                UV j = count[i];
                while (j--) {
                    *ptr = i;
                    ptr += record_size;
                }
            }
        }
        else {
            pos[0] = 0;
            for (i = 0; i < 255; i++)
                pos[i + 1] = pos[i] + count[i];
            
            for (i = 0; i < 255; i++) {
                unsigned char *current = pv + offset + pos[i] * record_size;
                unsigned char *top = current + count[i] * record_size;
                while (current < top) {
                    if (*current == i) {
                        pos[*current] ++;
                        current += record_size;
                    }
                    else {
                        unsigned char dest_char = *current;
                        unsigned char *dest = pv + offset + pos[dest_char] * record_size;
                        int k = record_size - offset;
                        while (0 < k-- ) {
                            unsigned char tmp = current[k];
                            current[k] = dest[k];
                            dest[k] = tmp;
                        }
                        pos[dest_char]++;
                        count[dest_char]--;
                    }
                }
            }
            
            /* dump_keys("out", pv, nelems, record_size, offset); */
            
            offset1 = offset + 1;
            if (offset1 < record_size) {
                pos[255] += count[255];
                for (last = i = 0; i < 256; last = pos[i++]) {
                    UV count = pos[i] - last;
                    if (count > 1)
                        radixsort(pv + last * record_size, count, record_size, offset1);
                }
            }
        }
    }
    else {
        UV i;
        for (i = 1; i < nelems; i++) {
            unsigned char *current = pv + i * record_size;
            UV min = 0, max = i;
            while (min < max) {
                UV pivot = (min + max) / 2;
                unsigned char *pivot_ptr = pv + pivot * record_size;
                UV j;
                /* fprintf(stderr, "min: %d, max: %d, pivot: %d\n", min, max, pivot); */
                for (j = offset; j < record_size; j++) {
                    if (pivot_ptr[j] < current[j]) {
                        min = pivot + 1;
                        goto continue_while_loop;
                    }
                    if (pivot_ptr[j] > current[j]) {
                        max = pivot;
                        goto continue_while_loop;
                    }
                }
                max = pivot;
                break;
            continue_while_loop:
                ;
            }
            /* fprintf(stderr, "rsize: %d, offset: %d, i: %d, max: %d\n",
                    record_size, offset, i, max);
                    dump_keys("before", pv, i + 1, record_size, offset); */
            if (max < i) {
                UV j;
                for (j = offset; j < record_size; j++) {
                    unsigned char *end = pv + max * record_size + j;
                    unsigned char *ptr = pv + i * record_size + j;
                    unsigned char tmp = *ptr;
                    while (ptr > end) {
                        unsigned char *next = ptr - record_size;
                        *ptr = *next;
                        ptr = next;
                        /* dump_keys("between", pv, i + 1, record_size, offset); */
                    }
                    *ptr = tmp;
                }
            }
            /* dump_keys("after", pv, i + 1, record_size, offset); */
        }
    }
}

static void
reverse_packed(char *ptr, IV len, IV record_size) {
    if (record_size % sizeof(unsigned int) == 0) {
        int *start, *end;
        record_size /= sizeof(int);
        start = (int *)ptr;
        end = start + (len - 1) * record_size;
        if (record_size == 1) {
            while (start < end) {
                int tmp = *start;
                *(start++) = *end;
                *(end--) = tmp;
            }
        }
        else {
            while (start < end) {
                int i;
                for (i = 0; i < record_size; i++) {
                    int tmp = *start;
                    *(start++) = *end;
                    *(end++) = tmp;
                }
                end -= record_size * 2;
            }
        }
    }
    else {
        char *start = (char *)ptr;
        char *end = start + (len - 1) * record_size;
        while (start < end) {
            int i;
            for (i = 0; i < record_size; i++) {
                char tmp = *start;
                *(start++) = *end;
                *(end++) = tmp;
            }
            end -= record_size * 2;
        }
    }
}

static void
pre_radix(unsigned char *pv, UV nelems, UV value_size, UV value_type, UV byte_order) {
    if (byte_order || value_type) {
        unsigned char *ptr = pv;
        unsigned char *end = ptr + nelems * value_size;
        UV value_size_1 = ( ( value_type == TYPE_FLOAT_X86
                              && (value_size == 12 || value_size == 16) )
                            ? 9
                            : value_size - 1 );
        while (ptr < end) {
            if (byte_order) {
                unsigned char tmp;
                unsigned char *from = ptr;
                unsigned char *to = ptr + value_size_1;
                while (from < to) {
                    tmp = *from;
                    *(from++) = *to;
                    *(to--) = tmp;
                }
            }
            if (value_type) {
                if (value_type == TYPE_SIGNED) 
                    *ptr ^= 0x80;
                else { /* TYPE_FLOAT */
                    if (*ptr & 0x80) {
                        unsigned char *from = ptr + value_size_1;
                        while (from >= ptr)
                            *(from--) ^= 0xff;
                    }
                    else {
                        *ptr |= 0x80;
                    }
                }
            }
            ptr += value_size;
        }
    }
}

static void
post_radix(unsigned char *pv, UV nelems, UV value_size, UV value_type, UV byte_order) {
    if (byte_order || value_type) {
        unsigned char *ptr = pv;
        unsigned char *end = ptr + nelems * value_size;
        UV value_size_1 = ( ( value_type == TYPE_FLOAT_X86
                              && (value_size == 12 || value_size == 16) )
                            ? 9
                            : value_size - 1 );
        while (ptr < end) {
            if (value_type) {
                if (value_type == TYPE_SIGNED) 
                    *ptr ^= 0x80;
                else { /* TYPE_FLOAT */
                    if (*ptr & 0x80)
                        *ptr &= 0x7f;
                    else {
                        unsigned char *from = ptr + value_size_1;
                        while (from >= ptr)
                            *(from--) ^= 0xff;
                    }
                }
            }
            if (byte_order) {
                unsigned char tmp;
                unsigned char *from = ptr;
                unsigned char *to = ptr + value_size_1;
                while (from < to) {
                    tmp = *from;
                    *(from++) = *to;
                    *(to--) = tmp;
                }
            }
            ptr += value_size;
        }
    }
}

typedef struct _cmp_extra {
    UV key_size;
    SV *cmp;
    SV *a, *b;
} my_extra;

static int
custom_cmp(pTHX_
           const unsigned char *a, const unsigned char *b,
           const my_extra *extra) {
    return 0;
}

static int 
uchar_cmp(pTHX_
          const unsigned char *a, const unsigned char *b,
          const my_extra *extra) {
    UV i = extra->key_size;
    while (--i) {
        if (*a != *b)
            return (*a < *b) ? -1 : 1;
        a++; b++;
    }
    return 0;
}

uint_cmp(pTHX_
         const unsigned int *a, const unsigned int *b,
         const my_extra *extra) {
    UV i = extra->key_size;
    while (--i) {
        if (*a != *b)
            return (*a < *b) ? -1 : 1;
        a++; b++;
    }
    return 0;
}

ulong_cmp(pTHX_
          const unsigned long *a, const unsigned long *b,
          const my_extra *extra) {
    UV i = extra->key_size;
    while (--i) {
        if (*a != *b)
            return (*a < *b) ? -1 : 1;
        a++; b++;
    }
    return 0;
}

static my_cmp_t
select_cmp(unsigned char *pv, UV *record_size) {
    if ( ((IV)pv) % sizeof(unsigned long) == 0 &&
         *record_size % sizeof(unsigned long) == 0 ) {
        *record_size /= sizeof(unsigned long);
        return (my_cmp_t)&ulong_cmp;
    }
    if ( ((IV)pv) % sizeof(unsigned int) == 0 &&
         *record_size % sizeof(unsigned int) == 0 ) {
        *record_size /= sizeof(unsigned int);
        return (my_cmp_t)&uint_cmp;
    }
    return (my_cmp_t)uchar_cmp;
}

static void
expand(unsigned char *from, UV nelems, UV rs, UV ers, unsigned char *to) {
    UV i = nelems;
    while (i-- > 0) {
        UV j = rs;
        while (j-- > 0) *(to++) = *(from++);
        j = ers - rs;
        while (j-- > 0) *(to++) = 0;
    }
}

static void
unexpand(unsigned char *from, UV nelems, UV rs, UV ers, unsigned char *to) {
    UV i = nelems;
    while (i-- > 0) {
        UV j = rs;
        while (j-- > 0) *(to++) = *(from++);
        from += ers - rs;
    }
}


MODULE = Sort::Packed		PACKAGE = Sort::Packed		

void
_radixsort_packed(vector, dir, value_size, value_type, byte_order, rep)
   SV *vector
   IV dir
   UV value_size
   UV value_type
   UV byte_order
   UV rep
CODE:
    STRLEN len;
    char *pv = SvPV(vector, len);
    UV record_size = value_size * rep;
    UV nelems;
    /* Perl_warn(aTHX_ "vector: %p, dir: %d, vsize: %d, vtype: %d bo: %d, rep: %d",
       vector, dir, value_size, value_type, byte_order, rep); */
    if (value_size == 0 || rep == 0 || dir == 0 ||
        byte_order > BYTE_ORDER_LAST || value_type > TYPE_LAST)
        Perl_croak(aTHX_ "internal error, bad value");
    if (len % record_size != 0)
        Perl_croak(aTHX_ "vector length %d is not a multiple of record size %d", len, record_size);
    nelems = len / record_size;
    if (nelems > 1) {
        pre_radix(pv, nelems * rep, value_size, value_type, byte_order);
        radixsort((unsigned char *)pv, nelems, record_size, 0);
        post_radix(pv, nelems * rep, value_size, value_type, byte_order);
        if (dir < 0)
            reverse_packed((unsigned char *)pv, nelems, record_size);
    }

void
_mergesort_packed(vector, cmp, dir, value_size, value_type, byte_order, rep)
    SV *vector
    SV *cmp
    IV dir
    UV value_size
    UV value_type
    UV byte_order
    UV rep
CODE:
    STRLEN len;
    unsigned char *pv = (unsigned char *)SvPV(vector, len);
    UV record_size = value_size * rep;
    UV expanded_record_size = record_size;
    UV nelems;
    my_extra extra;
    my_cmp_t ccmp;
    if (value_size == 0 || rep == 0 || dir == 0 ||
        byte_order > BYTE_ORDER_LAST || value_type > TYPE_LAST)
        Perl_croak(aTHX_ "internal error, bad value");
    if (len % record_size != 0)
        Perl_croak(aTHX_ "vector length %d is not a multiple of record size %d", len, record_size);
    nelems = len / record_size;
    if (nelems > 1) {
        extra.key_size = record_size;
        dump_keys("in", pv, nelems, record_size, 0);
        if (SvOK(cmp)) {
            SV *cv = SvRV(cmp);
            HV *stash;
            if (SvTYPE(cv) != SVt_PVCV)
                Perl_croak(aTHX_ "reference to comparison function expected");
            ccmp = (my_cmp_t)&custom_cmp;
            extra.cmp = cmp;
            extra.a = 0;
            extra.b = 0;
        }
        else {
            extra.cmp = 0;
            pre_radix(pv, nelems * rep, value_size, value_type, byte_order);
        }
        if (record_size < PSIZE / 2) {
            expanded_record_size = PSIZE / 2;
            Newx(pv, nelems * expanded_record_size, unsigned char);
            expand(SvPV_nolen(vector), nelems,
                   record_size, expanded_record_size,
                   pv);
        }
        if (!extra.cmp)
            ccmp = select_cmp(pv, &(extra.key_size));
        mergesort(aTHX_ pv, nelems, expanded_record_size, ccmp, &extra);
        
        if (expanded_record_size != record_size) {
            unexpand(pv, nelems,
                     record_size, expanded_record_size,
                     SvPV_nolen(vector));
            pv = SvPV_nolen(vector);
        }
        if (ccmp != (my_cmp_t)&custom_cmp)
            post_radix(pv, nelems * rep, value_size, value_type, byte_order);
        dump_keys("out", pv, nelems, record_size, 0);
    }
        

void
_reverse_packed(vector, record_size)
    SV *vector
    IV record_size
CODE:
    STRLEN len;
    char *pv = SvPV(vector, len);
    UV nelems;
    if (record_size <= 0)
        Perl_croak(aTHX_ "bad record size %d", record_size);
    if (len % record_size != 0)
        Perl_croak(aTHX_ "vector length %d is not a multiple of record nelems %d", len, record_size);
    nelems = len / record_size;
    reverse_packed((unsigned char *)pv, nelems, record_size);

