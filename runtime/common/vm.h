#pragma once
#ifdef VM_ENABLE
#include <VX_config.h>
#include <common.h>
#include <cstdint>
#include <mem.h>
#include <processor.h>
#include <unordered_map>
#include <random>
#include <util.h>

using namespace vortex;

class VMManager {
  public:
    VMManager(Processor* processor, RAM* ram);
    ~VMManager();

    int init();
    int phy_to_virt_map(uint64_t size, uint64_t* dev_pAddr, uint32_t flags);
    bool need_trans(uint64_t dev_pAddr);
    uint64_t page_table_walk(uint64_t vAddr_bits);
    uint64_t map_p2v(uint64_t ppn, uint32_t flags);
    int virtual_mem_reserve(uint64_t dev_addr, uint64_t size, int flags);

  private:
    int init_page_table(uint64_t addr, uint64_t size);
    uint8_t alloc_page_table(uint64_t* pt_addr);
    int16_t update_page_table(uint64_t ppn, uint64_t vpn, uint32_t flag);

    // helpers
    uint64_t read_pte(uint64_t addr);
    void write_pte(uint64_t addr, uint64_t value = 0xbaadf00d);
    uint64_t get_base_ppn();
    uint64_t get_pte_address(uint64_t base_ppn, uint64_t vpn);
    uint8_t get_mode();

    Processor* processor_;
    RAM* ram_;

    // memory allocators
    MemoryAllocator *page_table_mem_;
    MemoryAllocator *virtual_mem_;
    std::unordered_map<uint64_t, uint64_t> addr_mapping;
    
    // random number generator for randomized virtual address mapping
    std::mt19937_64 rng_;
    bool randomize_va_;
};

#endif // VM_ENABLE