/*
** SD-card emulator.
**
** 28-DEC-2016, B. Ulmann fecit
** 22-AUG-2022, sy2002 fixed SD card writing
*/

#include "sd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERBOSE

/*
** Two slots (Megamiga, M2M-UPSTREAM sd-host): the MEGA65 has one SD host
** controller per slot; register 7 selects the one that registers 0..6 address
** (0 = the bottom tray, 1 = the back slot). Register 6 reads bit 2 = card
** ready when an image is attached. "-a" attaches slot 0, "-a1" slot 1.
*/
#define SD_SLOTS 2

static FILE *images[SD_SLOTS] = { 0, 0 };
static unsigned int sd_slot = 0;
static unsigned int slot_addr_lo[SD_SLOTS], slot_addr_hi[SD_SLOTS], slot_data_pos[SD_SLOTS];
static unsigned char slot_data[SD_SLOTS][SD_SECTOR_SIZE];

#define image        images[sd_slot]
#define sd_addr_lo   slot_addr_lo[sd_slot]
#define sd_addr_hi   slot_addr_hi[sd_slot]
#define sd_data_pos  slot_data_pos[sd_slot]
#define sd_data      slot_data[sd_slot]

unsigned static int sd_error = 0;

#ifdef DEBUG
void dump_sd_buffer()
{
    int i;

    for (i = 0; i < SD_SECTOR_SIZE; i++)
    {
        if (!(i % 16)) printf("\n");
        printf("%02x ", sd_data[i]);
    }
    printf("\n");
}
#endif

void sd_attach_slot(unsigned int slot, char *filename)
{
  unsigned int keep = sd_slot;

#ifdef DEBUG
  printf("sd_init: Open >>%s<< (slot %u)\n", filename, slot);
#endif

  sd_slot = slot & 1;
  if (image) /* If there is already an image attached, detach it first. */
    sd_detach();

  if (!(image = fopen(filename, "r+b")))
    printf("Unable to attach SD-card image file >>%s<<!\n", filename);
  sd_slot = keep;
}

void sd_attach(char *filename)
{
  sd_attach_slot(0, filename);
}

void sd_detach()
{
  if (image)
  {
    fclose(image);
#ifdef DEBUG
    printf("sd_detach: fclose()\n");
#endif    
  }
  image = 0;
  memset(sd_data, 0, SD_SECTOR_SIZE);
}

void sd_write_register(unsigned int address, unsigned int value)
{
  unsigned int block_start_address;

#ifdef DEBUG
  printf("sd_write_register(%04X, %04X)\n", address & 0xffff, value & 0xffff);
#endif
  switch (address)
  {
    case SD_ADDR_LO:
      sd_addr_lo = value & 0xffff;
      break;
    case SD_ADDR_HI:
      sd_addr_hi = value & 0xffff;
      break;
    case SD_DATA_POS:
      sd_data_pos = value & 0xffff;
      break;
    case SD_DATA:
      sd_data[sd_data_pos & 0x01ff] = value & 0xffff;
      break;
    case SD_MODE: /* SPI only: nothing to emulate */
      break;
    case SD_SLOT:
      sd_slot = value & 1;
      break;
    case SD_CSR:
      if ((value & 0xffff) == 1) /* Read 512 bytes from the block addressed by the current LBA. */
      {
        block_start_address = ((sd_addr_lo & 0xffff) | ((sd_addr_hi & 0xfff) << 16)) * SD_SECTOR_SIZE;
        if (image)
        {
          fseek(image, block_start_address, SEEK_SET);
          fread(sd_data, SD_SECTOR_SIZE, 1, image);
        }
#ifdef DEBUG
        printf("SD: Read block %08X.\n", (sd_addr_lo & 0xffff) | ((sd_addr_hi & 0xfff) << 16));
        dump_sd_buffer();
#endif
      }
      else if ((value & 0xffff) == 2) /* Write 512 bytes to the block address by the current LBA. */
      {
        block_start_address = ((sd_addr_lo & 0xffff) | ((sd_addr_hi & 0xfff) << 16)) * SD_SECTOR_SIZE;
#ifdef DEBUG
        printf("SD: Write block %08X.\n", block_start_address);
        dump_sd_buffer();
#endif
        if (image)
        {
          fseek(image, block_start_address, SEEK_SET);
          fwrite(sd_data, SD_SECTOR_SIZE, 1, image);
        }
      }
      break;
    default:
#ifdef VERBOSE
      printf("sd_write_register: attempt to write illegal register %04X <- %04X.\n", address & 0xffff, value & 0xffff);
#endif
  }
}

unsigned int sd_read_register(unsigned int address)
{
  unsigned int value;

  switch (address)
  {
    case SD_ADDR_LO:
      value = sd_addr_lo;
      break;
    case SD_ADDR_HI:
      value = sd_addr_hi;
      break;
    case SD_DATA_POS:
      value = sd_data_pos;
      break;
    case SD_DATA:
      value = sd_data[sd_data_pos & 0x01ff];
#ifdef DEBUG
      printf("SD: Read from buffer [%05X]: %04X\n", sd_data_pos & 0x01ff, value);
#endif
      break;
    case SD_ERROR:
      value = sd_error & 0xffff;
      break;
    case SD_CSR: /* More or less a dummy operation as there is no room for errors in the emulation. :-) */
      value = 0x2000; /* Report card type SD V2. */
      break;
    case SD_MODE: /* bit 2: ready (a card is there) */
      value = image ? 0x0004 : 0;
      break;
    case SD_SLOT:
      value = sd_slot;
      break;
    default:
#ifdef VERBOSE
      printf("sd_read_register: attempt to read illegal register %04X.\n", address);
#endif
  }

#ifdef DEBUG
  printf("sd_read_register(%04X) -> %04X\n", address & 0xffff, value & 0xffff);
#endif

  return value & 0xffff;
}
