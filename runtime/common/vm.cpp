// Copyright © 2019-2025
// Licensed under the Apache License, Version 2.0
// See LICENSE file for details.

#ifdef VM_ENABLE
#include "vm.h"

#include <VX_config.h>
#include <cassert>
#include <cmath>
#include <iostream>
#include <unordered_map>

using namespace vortex;

VMManager::VMManager(Processor *processor, RAM *ram)
    : processor_(processor),
      ram_(ram),
      page_table_mem_(nullptr),
      virtual_mem_(nullptr) {
  const char* randomize_env = std::getenv("VORTEX_RANDOMIZE_VA");
  randomize_va_ = (randomize_env != nullptr && std::atoi(randomize_env) != 0);
  
  const char* seed_env = std::getenv("VORTEX_VA_SEED");
  uint64_t seed = seed_env ? std::atoll(seed_env) : 0x12345678ULL;
  rng_.seed(seed);
  
  if (randomize_va_) {
    std::cout << "[VM] Virtual address randomization ENABLED (seed=0x" << std::hex << seed << std::dec << ")" << std::endl;
  }
}

VMManager::~VMManager() {
  delete virtual_mem_;
  delete page_table_mem_;
}

/*=========================================================
    Initialization
=========================================================*/

// reserve IO space, startup space, and local mem area
int VMManager::virtual_mem_reserve(uint64_t dev_addr, uint64_t size, int flags) {
  CHECK_ERR(virtual_mem_->reserve(dev_addr, size), {
    return err;
  });
  DBGPRINT("[RT:mem_reserve] addr: 0x%lx, size:0x%lx, size: 0x%lx\n", dev_addr, size, size);
  return 0;
}


int VMManager::init() {
  uint64_t pt_addr = 0;
  std::cout << "VMManager Initialization..." << std::endl;
  page_table_mem_ = new MemoryAllocator(PAGE_TABLE_BASE_ADDR, PT_SIZE_LIMIT, MEM_PAGE_SIZE, CACHE_BLOCK_SIZE);
  if (page_table_mem_ == NULL) {
    return 1;
  }

  // HW: virtual mem allocator has the same address range as global_mem. next step is to adjust it
  // For 32-bit mode, ensure virtual addresses stay within 32-bit range
  uint64_t virtual_mem_size = (GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR);
  #ifdef XLEN_32
  uint64_t max_va_end = 0x100000000ULL; // 4GB limit for 32-bit
  if (ALLOC_BASE_ADDR + virtual_mem_size > max_va_end) {
    virtual_mem_size = max_va_end - ALLOC_BASE_ADDR;
  }
  #endif
  
  virtual_mem_ = new MemoryAllocator(ALLOC_BASE_ADDR, virtual_mem_size, MEM_PAGE_SIZE, CACHE_BLOCK_SIZE);
  
  uint64_t pt_reserve_size = (GLOBAL_MEM_SIZE - PAGE_TABLE_BASE_ADDR);
  #ifdef XLEN_32
  if (PAGE_TABLE_BASE_ADDR + pt_reserve_size > max_va_end) {
    pt_reserve_size = max_va_end - PAGE_TABLE_BASE_ADDR;
  }
  #endif
  CHECK_ERR(virtual_mem_reserve(PAGE_TABLE_BASE_ADDR, pt_reserve_size, VX_MEM_READ_WRITE), {
    return err;
  });
  
  CHECK_ERR(virtual_mem_reserve(STARTUP_ADDR, 0x40000, VX_MEM_READ_WRITE), {
    return err;
  });

  if (virtual_mem_ == nullptr) {
    // virtual_mem_ does not intefere with physical mem, so no need to free space
    return 1;
  }

  if (VM_ADDR_MODE == BARE)
    DBGPRINT("[RT:init_VM] VA_MODE = BARE MODE(addr= 0x0)");
  else
    CHECK_ERR(alloc_page_table(&pt_addr), { return err; });

  CHECK_ERR(processor_->set_satp_by_addr(pt_addr), { return err; });
  return 0;
}

/*=========================================================
   Address Mapping and Translation
=========================================================*/

bool VMManager::need_trans(uint64_t dev_pAddr) {
  // Check if the satp is set and BARE mode
  if (processor_->is_satp_unset() || get_mode() == BARE)
    return 0;

  // Skip reserved and IO regions
  if (PAGE_TABLE_BASE_ADDR <= dev_pAddr)
    return 0;
  if (dev_pAddr < USER_BASE_ADDR)
    return 0;

  // Check if the address falls within the startup address range
  if ((STARTUP_ADDR <= dev_pAddr) && (dev_pAddr <= (STARTUP_ADDR + 0x40000)))
    return 0;

  // Now all conditions are not met. Return true because the address needs translation
  return 1;
}

// physical (ppn) to virtual (vpn) mapping
uint64_t VMManager::map_p2v(uint64_t ppn, uint32_t flags) {
  DBGPRINT(" [RT:MAP_P2V] ppn: %lx\n", ppn);
  if (addr_mapping.find(ppn) != addr_mapping.end())
    return addr_mapping[ppn];

  // If ppn to vpn mapping doesnt exist, create mapping
  DBGPRINT(" [RT:MAP_P2V] Not found. Allocate new page table or update a PTE.\n");
  uint64_t vpn;
  
  if (randomize_va_) {
    // Randomized virtual address allocation
    const int MAX_ATTEMPTS = 1000;
    bool allocated = false;
    
    for (int attempt = 0; attempt < MAX_ATTEMPTS; ++attempt) {
      uint64_t va_range_start = ALLOC_BASE_ADDR;
      uint64_t va_range_end = PAGE_TABLE_BASE_ADDR;
      
      // For 32-bit mode (XLEN=32), constrain VAs to fit in 32-bit address space
      #ifdef XLEN_32
      uint64_t max_va = 0xFFFFFFFFULL;
      if (va_range_end > max_va) {
        va_range_end = max_va;
      }
      #endif
      
      uint64_t va_range_size = va_range_end - va_range_start;
      uint64_t max_pages = va_range_size >> MEM_PAGE_LOG2_SIZE;
      
      std::uniform_int_distribution<uint64_t> dist(0, max_pages - 1);
      uint64_t random_page_offset = dist(rng_);
      uint64_t candidate_va = va_range_start + (random_page_offset << MEM_PAGE_LOG2_SIZE);
      
      // Check if this virtual address is already in use
      bool in_use = false;
      for (const auto& mapping : addr_mapping) {
        if (mapping.second == (candidate_va >> MEM_PAGE_LOG2_SIZE)) {
          in_use = true;
          break;
        }
      }
      
      if (!in_use && virtual_mem_->reserve(candidate_va, MEM_PAGE_SIZE) == 0) {
        vpn = candidate_va >> MEM_PAGE_LOG2_SIZE;
        allocated = true;
        DBGPRINT(" [RT:MAP_P2V] Randomized: ppn 0x%lx -> vpn 0x%lx (vaddr 0x%lx)\n", ppn, vpn, candidate_va);
        break;
      }
    }
    
    if (!allocated) {
      DBGPRINT(" [RT:MAP_P2V] Random allocation failed, falling back to sequential\n");
      virtual_mem_->allocate(MEM_PAGE_SIZE, &vpn);
      vpn >>= MEM_PAGE_LOG2_SIZE;
    }
  } else {
    virtual_mem_->allocate(MEM_PAGE_SIZE, &vpn);
    vpn >>= MEM_PAGE_LOG2_SIZE;
  }
  
  CHECK_ERR(update_page_table(ppn, vpn, flags), );
  addr_mapping[ppn] = vpn;
  return vpn;
}

int VMManager::phy_to_virt_map(uint64_t size, uint64_t *dev_pAddr, uint32_t flags) {
  DBGPRINT(" [RT:PTV_MAP] size = 0x%lx, dev_pAddr= 0x%lx, flags = 0x%x\n", size, *dev_pAddr, flags);
  DBGPRINT(" [RT:PTV_MAP] bit mode: %d\n", XLEN);

  if (!need_trans(*dev_pAddr)) {
    DBGPRINT(" [RT:PTV_MAP] Translation is not needed.\n");
    return 0;
  }

  uint64_t init_pAddr = *dev_pAddr;
  uint64_t num_pages = size >> MEM_PAGE_LOG2_SIZE;
  uint64_t base_ppn = init_pAddr >> MEM_PAGE_LOG2_SIZE;
  
  uint64_t base_vpn;
  
  // Check if first page is already mapped
  if (addr_mapping.find(base_ppn) != addr_mapping.end()) {
    base_vpn = addr_mapping[base_ppn];
    DBGPRINT(" [RT:PTV_MAP] Base page already mapped: ppn 0x%lx -> vpn 0x%lx\n", base_ppn, base_vpn);
  } else {
    uint64_t base_va;
    if (randomize_va_) {
      // For randomized allocation, try to find a random contiguous VA range
      const int MAX_ATTEMPTS = 1000;
      bool allocated = false;
      
      for (int attempt = 0; attempt < MAX_ATTEMPTS && !allocated; ++attempt) {
        uint64_t va_range_start = ALLOC_BASE_ADDR;
        uint64_t va_range_end = PAGE_TABLE_BASE_ADDR;
        
        #ifdef XLEN_32
        uint64_t max_va = 0xFFFFFFFFULL;
        if (va_range_end > max_va) {
          va_range_end = max_va;
        }
        #endif
        
        uint64_t va_range_size = va_range_end - va_range_start;
        uint64_t max_pages = (va_range_size >> MEM_PAGE_LOG2_SIZE) - num_pages;
        
        std::uniform_int_distribution<uint64_t> dist(0, max_pages - 1);
        uint64_t random_page_offset = dist(rng_);
        uint64_t candidate_va = va_range_start + (random_page_offset << MEM_PAGE_LOG2_SIZE);
        
        bool range_available = true;
        for (uint64_t i = 0; i < num_pages && range_available; ++i) {
          uint64_t test_vpn = (candidate_va >> MEM_PAGE_LOG2_SIZE) + i;
          for (const auto& mapping : addr_mapping) {
            if (mapping.second == test_vpn) {
              range_available = false;
              break;
            }
          }
        }
        
        if (range_available && virtual_mem_->reserve(candidate_va, size) == 0) {
          base_va = candidate_va;
          allocated = true;
          DBGPRINT(" [RT:PTV_MAP] Reserved random contiguous VA range: 0x%lx (size 0x%lx)\n", base_va, size);
        }
      }
      
      if (!allocated) {
        // Fallback to sequential allocation
        base_va = 0;
        CHECK_ERR(virtual_mem_->allocate(size, &base_va), );
        DBGPRINT(" [RT:PTV_MAP] Fallback: allocated sequential VA range: 0x%lx (size 0x%lx)\n", base_va, size);
      }
    } else {
      base_va = 0;
      CHECK_ERR(virtual_mem_->allocate(size, &base_va), );
      DBGPRINT(" [RT:PTV_MAP] Allocated sequential VA range: 0x%lx (size 0x%lx)\n", base_va, size);
    }
    
    base_vpn = base_va >> MEM_PAGE_LOG2_SIZE;
  }
  
  uint64_t init_vAddr = (base_vpn << MEM_PAGE_LOG2_SIZE) | (init_pAddr & ((1 << MEM_PAGE_LOG2_SIZE) - 1));

  for (uint64_t i = 0; i < num_pages; i++) {
    uint64_t ppn = base_ppn + i;
    uint64_t vpn = base_vpn + i;
    
    if (addr_mapping.find(ppn) == addr_mapping.end()) {
      CHECK_ERR(update_page_table(ppn, vpn, flags), );
      addr_mapping[ppn] = vpn;
      DBGPRINT(" [RT:PTV_MAP] Mapped ppn 0x%lx to vpn 0x%lx\n", ppn, vpn);
    }
  }
  
  DBGPRINT(" [RT:PTV_MAP] Mapped virtual addr: 0x%lx to physical addr: 0x%lx\n", init_vAddr, init_pAddr);
  assert(page_table_walk(init_vAddr) == init_pAddr && "ERROR: translated virtual Addresses are not the same with physical Address\n");

  *dev_pAddr = init_vAddr; // commit vpn to be returned to host
  DBGPRINT(" [RT:PTV_MAP] Translated device virtual addr: 0x%lx\n", *dev_pAddr);

  return 0;
}

/*=========================================================
   Page Table Helpers
=========================================================*/

uint8_t VMManager::alloc_page_table(uint64_t *pt_addr) {
  CHECK_ERR(page_table_mem_->allocate(PT_SIZE, pt_addr), { return err; });
  CHECK_ERR(init_page_table(*pt_addr, PT_SIZE), { return err; });
  DBGPRINT("   [RT:alloc_page_table] addr= 0x%lx\n", *pt_addr);
  return 0;
}

// Initialize to zero the target page table area. 32bit 4K, 64bit 8K
int VMManager::init_page_table(uint64_t addr, uint64_t size) {
  uint64_t asize = aligned_size(size, CACHE_BLOCK_SIZE);
  DBGPRINT("  [RT:init_page_table] (addr=0x%lx, size=0x%lx)\n", addr, asize);
  uint8_t *src = new uint8_t[asize];
  if (src == NULL)
    return 1;

  for (uint64_t i = 0; i < asize; ++i) {
    src[i] = 0;
  }
  ram_->enable_acl(false);
  ram_->write((const uint8_t *)src, addr, asize);
  ram_->enable_acl(true);
  return 0;
}

int16_t VMManager::update_page_table(uint64_t ppn, uint64_t vpn, uint32_t flag) {
  DBGPRINT("  [RT:Update PT] Mapping vpn 0x%05lx to ppn 0x%05lx(flags = %u)\n", vpn, ppn, flag);
  // sanity check
#if VM_ADDR_MODE == SV39
  assert((((ppn >> 44) == 0) && ((vpn >> 27) == 0)) && "Upper bits are not zero!");
  uint8_t level = 3;
#else // Default is SV32, BARE will not reach this point.
  assert((((ppn >> 20) == 0) && ((vpn >> 20) == 0)) && "Upper 12 bits are not zero!");
  uint8_t level = 2;
#endif
  int i = level - 1;
  vAddr_t vaddr(vpn << MEM_PAGE_LOG2_SIZE);
  uint64_t pte_addr = 0, pte_bytes = 0;
  uint64_t pt_addr = 0;
  uint64_t cur_base_ppn = get_base_ppn();

  while (i >= 0) {
    DBGPRINT("  [RT:Update PT]Start %u-level page table\n", i);
    pte_addr = get_pte_address(cur_base_ppn, vaddr.vpn[i]);
    pte_bytes = read_pte(pte_addr);
    PTE_t pte_chk(pte_bytes);
    DBGPRINT("  [RT:Update PT] PTE addr 0x%lx, PTE bytes 0x%lx\n", pte_addr, pte_bytes);
    if (pte_chk.v == 1 && ((pte_bytes & 0xFFFFFFFF) != 0xbaadf00d)) {
      DBGPRINT("  [RT:Update PT] PTE valid (ppn 0x%lx), continuing the walk...\n", pte_chk.ppn);
      cur_base_ppn = pte_chk.ppn;
    } else {
      // If valid bit not set, allocate a next level page table
      DBGPRINT("  [RT:Update PT] PTE Invalid (ppn 0x%lx) ...\n", pte_chk.ppn);
      if (i == 0) {
        // Reach to leaf
        DBGPRINT("  [RT:Update PT] Reached to level 0. This should be a leaf node(flag = %x) \n", flag);
        uint32_t pte_flag = (flag << 1) | 0x3;
        PTE_t new_pte(ppn << MEM_PAGE_LOG2_SIZE, pte_flag);
        write_pte(pte_addr, new_pte.pte_bytes);
        break;
      } else {
        //  in device memory and store ppn in PTE. Set rwx = 000 in PTE
        // to indicate this is a pointer to the next level of the page table.
        // flag would READ: 0x1, Write 0x2, RW:0x3, which is matched with PTE flags if it is lsh by one.
        alloc_page_table(&pt_addr);
        uint32_t pte_flag = 0x1;
        PTE_t new_pte(pt_addr, pte_flag);
        write_pte(pte_addr, new_pte.pte_bytes);
        cur_base_ppn = new_pte.ppn;
      }
    }
    i--;
  }
  return 0;
}

/*=========================================================
   Page Table Walk
=========================================================*/

uint64_t VMManager::page_table_walk(uint64_t vAddr_bits) {
  DBGPRINT("  [RT:PTW] start vAddr: 0x%lx\n", vAddr_bits);
  if (!need_trans(vAddr_bits)) {
    DBGPRINT("  [RT:PTW] Translation is not needed.\n");
    return vAddr_bits;
  }
  uint8_t level = PT_LEVEL;
  int i = level - 1;
  vAddr_t vaddr(vAddr_bits);
  uint64_t pte_addr = 0, pte_bytes = 0;
  uint64_t cur_base_ppn = get_base_ppn();
  while (true) {
    DBGPRINT("  [RT:PTW]Start %u-level page table walk\n", i);
    // Read PTE.
    pte_addr = get_pte_address(cur_base_ppn, vaddr.vpn[i]);
    pte_bytes = read_pte(pte_addr);
    PTE_t pte(pte_bytes);
    DBGPRINT("  [RT:PTW] PTE addr 0x%lx, PTE bytes 0x%lx\n", pte_addr, pte_bytes);

    assert(((pte.pte_bytes & 0xFFFFFFFF) != 0xbaadf00d) && "ERROR: uninitialzed PTE\n");
    // Check if it has invalid flag bits.
    if ((pte.v == 0) | ((pte.r == 0) & (pte.w == 1))) {
      std::string msg = "  [RT:PTW] Page Fault : Attempted to access invalid entry.";
      throw Page_Fault_Exception(msg);
    }

    if ((pte.r == 0) & (pte.w == 0) & (pte.x == 0)) {
      i--;
      // Not a leaf node as rwx == 000
      if (i < 0) {
        throw Page_Fault_Exception("  [RT:PTW] Page Fault : No leaf node found.");
      } else {
        // Continue on to next level.
        cur_base_ppn = pte.ppn;
        DBGPRINT("  [RT:PTW] next base_ppn: 0x%lx\n", cur_base_ppn);
        continue;
      }
    } else {
      // Leaf node found.
      // Check RWX permissions according to access type.
      if (pte.r == 0) {
        throw Page_Fault_Exception("  [RT:PTW] Page Fault : TYPE LOAD, Incorrect permissions.");
      }
      cur_base_ppn = pte.ppn;
      DBGPRINT("  [RT:PTW] Found PT_Base_Address(0x%lx) on Level %d.\n", pte.ppn, i);
      break;
    }
  }
  uint64_t paddr = (cur_base_ppn << MEM_PAGE_LOG2_SIZE) + vaddr.pgoff;
  return paddr;
}

/*=========================================================
    misc helpers: DONE?
=========================================================*/

void VMManager::write_pte(uint64_t addr, uint64_t value) {
  DBGPRINT("  [RT:Write_pte] writing pte 0x%lx to pAddr: 0x%lx\n", value, addr);
  uint8_t *src = new uint8_t[PTE_SIZE];
  for (uint64_t i = 0; i < PTE_SIZE; ++i) {
    src[i] = (value >> (i << 3)) & 0xff;
  }
  ram_->enable_acl(false);
  ram_->write((const uint8_t *)src, addr, PTE_SIZE);
  ram_->enable_acl(true);
}

uint64_t VMManager::read_pte(uint64_t addr) {
  uint8_t *dest = new uint8_t[PTE_SIZE];
#ifdef XLEN_32
  uint64_t mask = 0x00000000FFFFFFFF;
#else // 64bit
  uint64_t mask = 0xFFFFFFFFFFFFFFFF;
#endif

  ram_->read((uint8_t *)dest, addr, PTE_SIZE);
  uint64_t ret = (*(uint64_t *)((uint8_t *)dest)) & mask;
  DBGPRINT("  [RT:read_pte] reading PTE 0x%lx from RAM addr 0x%lx\n", ret, addr);

  return ret;
}

uint64_t VMManager::get_base_ppn() {
  return processor_->get_base_ppn();
}

uint64_t VMManager::get_pte_address(uint64_t base_ppn, uint64_t vpn) {
  return (base_ppn * PT_SIZE) + (vpn * PTE_SIZE);
}

uint8_t VMManager::get_mode() {
  return processor_->get_satp_mode();
}

#endif // VM_ENABLE