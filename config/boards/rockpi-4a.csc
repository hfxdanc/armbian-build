# Rockchip RK3399 hexa core 1-4GB SoC GBe eMMC USB3
BOARD_NAME="Rockpi 4A"
BOARDFAMILY="rockchip64"
BOARD_MAINTAINER="clee"
BOOTCONFIG="rock-pi-4-rk3399_defconfig"
KERNEL_TARGET="current,edge"
KERNEL_TEST_TARGET="current"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3399-rock-pi-4a.dtb"
BOOT_SCENARIO="tpl-spl-blob"
BOOT_SUPPORT_SPI=yes
DDR_BLOB="rk33/rk3399_ddr_933MHz_v1.20.bin"
