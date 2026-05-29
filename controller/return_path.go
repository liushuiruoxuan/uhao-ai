package controller

import (
	"strings"

	"github.com/QuantumNous/uhao-api/common"
	"github.com/QuantumNous/uhao-api/setting/system_setting"
)

func paymentReturnPath(suffix string) string {
	base := strings.TrimRight(system_setting.ServerAddress, "/")
	return base + common.ThemeAwarePath(suffix)
}
