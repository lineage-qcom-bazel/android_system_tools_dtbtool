# SPDX-License-Identifier: GPL-2.0

_MERGE_CMD = """
            set -e
            EXECROOT=$$PWD
            DTB_IMG=$$EXECROOT/$(execpath {tv}/dtb.img)
            DTBO_IMG=$$EXECROOT/$(execpath {tv}/dtbo.img)
            MERGE_DTBS=$$EXECROOT/$(execpath {merge_dtbs})
            MKDTBOIMG=$$EXECROOT/$(execpath {mkdtboimg})

            WORK=$$(mktemp -d)
            trap 'rm -rf "$$WORK"' EXIT

            TOOLBIN=$$WORK/bin
            mkdir -p $$TOOLBIN
            for t in {path_tools}; do
                ln -sf "$$EXECROOT/$$t" "$$TOOLBIN/$$(basename $$t)"
            done

            KOUT=$$WORK/kernel_out
            mkdir -p $$KOUT
            cp -a $(execpath {kernel_config})/. $$KOUT/
            chmod -R u+w $$KOUT
            (
                # The Kleaf env script is not written for `set -u`.
                set +u
                . $(execpath {kernel_env})
                export OUT_DIR=$$KOUT
                make -C $${{KERNEL_DIR}} $${{TOOL_ARGS}} O=$${{OUT_DIR}} dtbs

                # //external/dtc has no fdtoverlaymerge target; build it from
                # source, reachable through the execroot since the action is local.
                if [ ! -e $$TOOLBIN/fdtoverlaymerge ]; then
                    DTC_SRC=$$(realpath $$EXECROOT/system/tools/dtbtool)/../../../external/dtc
                    mkdir -p $$WORK/dtc_gen
                    echo '#define DTC_VERSION "DTC lineage"' > $$WORK/dtc_gen/version_gen.h
                    $${{HOSTCC}} $${{HOSTCFLAGS}} -DNO_YAML -w \\
                        -I$$DTC_SRC -I$$DTC_SRC/libfdt -I$$WORK/dtc_gen \\
                        $$DTC_SRC/fdtoverlaymerge.c $$DTC_SRC/util.c $$DTC_SRC/libfdt/*.c \\
                        $${{HOSTLDFLAGS}} -o $$TOOLBIN/fdtoverlaymerge
                fi
            )

            # Base comes from kernel_build outs (product filtered), not
            # dts/vendor/*/*.dtb* like kernel.mk: other SoC bases built by
            # kbuild fail to merge with their techpacks.
            DTS=$$(echo $$KOUT/arch/*/boot/dts/vendor)
            BASE=$$WORK/base
            MERGED=$$WORK/out
            mkdir -p $$BASE $$MERGED
            find $$DTS -mindepth 2 -maxdepth 2 -type f \\( -name '*.dtb' -o -name '*.dtbo' \\) -delete
            for f in $(locations {kernel_build}); do
                case "$$f" in
                    *.dtb|*.dtbo) cp "$$f" $$BASE/ ;;
                esac
            done
            if [ -z "$$(ls $$BASE)" ]; then
                echo "ERROR: {kernel_build} exports no dtb/dtbo" >&2
                exit 1
            fi

            PATH=$$TOOLBIN:$$PATH python3 $$MERGE_DTBS \\
                --base $$BASE --techpack $$DTS --out $$MERGED

            DTBS=$$(find $$MERGED -type f -name "{dtb_wildcard}.dtb" | sort)
            DTBOS=$$(find $$MERGED -type f -name "{dtbo_wildcard}.dtbo" | sort)
            if [ -z "$$DTBS" ] || [ -z "$$DTBOS" ]; then
                echo "ERROR: merge_dtbs.py produced no dtb or dtbo" >&2
                exit 1
            fi
            cat $$DTBS > $$DTB_IMG
            $$MKDTBOIMG create $$DTBO_IMG --page_size={page_size} $$DTBOS
"""

def _merge_cmd(fmt_args, dtb_wildcard, dtbo_wildcard):
    return _MERGE_CMD.format(
        dtb_wildcard = dtb_wildcard,
        dtbo_wildcard = dtbo_wildcard,
        **fmt_args
    )

def target_merged_dtb(
        tv,
        kernel_build,
        page_size = 4096,
        dtb_wildcard = "*",
        dtbo_wildcard = "*",
        wildcards_by_condition = None,
        fdtoverlaymerge = None):
    """Builds merged dtb.img and dtbo.img like kernel.mk with BOARD_USES_QCOM_MERGE_DTBS_SCRIPT.

    kernel_build only exports the device trees in its outs, not the techpack
    overlays, so `make dtbs` is rerun against its public _env and _config
    targets. The action is local because the env needs the source tree.

    Args:
      tv: <msm_target>_<variant>, used for naming.
      kernel_build: label of the kernel_build.
      page_size: page size passed to mkdtboimg.
      dtb_wildcard: like TARGET_MERGE_DTBS_WILDCARD.
      dtbo_wildcard: like TARGET_MERGE_DTBOS_WILDCARD.
      wildcards_by_condition: optional dict of config_setting label ->
        (dtb_wildcard, dtbo_wildcard), e.g. per Motorola product. Conditions
        that don't match fall back to dtb_wildcard/dtbo_wildcard.
      fdtoverlaymerge: optional label of an fdtoverlaymerge binary. If unset,
        one is compiled from external/dtc inside the action.
    """

    path_tools = [
        "//external/dtc:fdtget",
        "//external/dtc:fdtput",
        "//external/dtc:fdtoverlay",
        "//prebuilts/kernel-build-tools:linux-x86/bin/ufdt_apply_overlay",
    ]
    if fdtoverlaymerge:
        path_tools.append(fdtoverlaymerge)
    mkdtboimg = "//prebuilts/kernel-build-tools:linux-x86/bin/mkdtboimg"
    merge_dtbs = "//system/tools/dtbtool:merge_dtbs.py"
    kernel_env = "{}_env".format(kernel_build)
    kernel_config = "{}_config".format(kernel_build)

    fmt_args = dict(
        tv = tv,
        kernel_build = kernel_build,
        merge_dtbs = merge_dtbs,
        mkdtboimg = mkdtboimg,
        kernel_env = kernel_env,
        kernel_config = kernel_config,
        path_tools = " ".join(["$(execpath {})".format(t) for t in path_tools]),
        page_size = page_size,
    )
    cmd = _merge_cmd(fmt_args, dtb_wildcard, dtbo_wildcard)
    if wildcards_by_condition:
        cmds = {
            condition: _merge_cmd(fmt_args, w[0], w[1])
            for condition, w in wildcards_by_condition.items()
        }
        cmds["//conditions:default"] = cmd
        cmd = select(cmds)

    native.genrule(
        name = "{}_merged_dtb".format(tv),
        srcs = [
            # Also ensures the hermetic toolchain used by the env script exists.
            kernel_build,
            kernel_env,
            kernel_config,
        ],
        outs = [
            "{}/dtb.img".format(tv),
            "{}/dtbo.img".format(tv),
        ],
        tools = [merge_dtbs, mkdtboimg] + path_tools,
        local = True,
        cmd = cmd,
    )
